import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.9.4 bug hunt, round 3: the R2 review's findings, against fake Homebrew.

/// Wraps a client's runner: the status read (`brew info --installed`) can
/// fail, or (armed once) read brew's answer at once and then hold it until
/// released: a read that began before a change and ends after it.
final class V094StatusRunner: CommandRunning, @unchecked Sendable {
    /// One held read: `sampled` opens once it has its (old) answer; it
    /// returns that once `gate` is released.
    struct Hold { let sampled = Latch(); let gate = Latch() }
    let inner: CommandRunning
    private let lock = NSLock()
    private var pending: Hold?
    private var all: [Hold] = []
    private var _fail = false
    private var _held = 0
    /// Changes `brew info --installed`'s answer (sampled when asked).
    var transform: (@Sendable (Data) -> Data)?

    init(_ inner: CommandRunning) { self.inner = inner }

    var fail: Bool {
        get { lock.withLock { _fail } }
        set { lock.withLock { _fail = newValue } }
    }
    /// How many reads were held.
    var held: Int { lock.withLock { _held } }
    /// Holds the next status read.
    @discardableResult func arm() -> Hold {
        let h = Hold()
        lock.withLock { pending = h; all.append(h) }
        return h
    }
    /// Lets every held read go (a failed test's cleanup).
    func releaseAll() { lock.withLock { all }.forEach { $0.gate.release() } }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        guard arguments == ["info", "--json=v2", "--installed"] else {
            return try await inner.run(executable, arguments, environment: environment)
        }
        if fail { return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Error: simulated read failure\n".utf8)) }
        var r = try await inner.run(executable, arguments, environment: environment)
        if let transform { r = ProcessResult(exitCode: r.exitCode, stdout: transform(r.stdout), stderr: r.stderr) }
        let hold = lock.withLock { () -> Hold? in
            defer { pending = nil }
            if pending != nil { _held += 1 }
            return pending
        }
        if let hold {
            hold.sampled.release()
            await hold.gate.wait()
        }
        return r
    }
}

/// The store, for a fake command that runs before it exists.
final class V094StoreBox: @unchecked Sendable {
    @MainActor var store: AppStore?
}

/// `deps` with its client's runner wrapped.
@MainActor
func v094WrapStatus(_ deps: inout AppStore.Dependencies, configure: (inout BrewClient) -> Void = { _ in }) throws -> V094StatusRunner {
    var client = try deps.makeClient()
    let runner = V094StatusRunner(client.runner)
    client.runner = runner
    configure(&client)
    let fixed = client
    deps.makeClient = { fixed }
    return runner
}

// MARK: MUST-FIX 1: Upgrade waits for a read after Auto-update's upgrades

// Auto-update's last read could fail (or join a read begun before its last
// upgrade) and leave the old list on screen. Once it ended, an open plan's
// Upgrade revalidated against that same list and ran what Auto-update had
// already upgraded.
@MainActor
struct V094StaleAfterAutoUpdateTests {
    @Test func aFailedReadAfterAutoUpdateKeepsThePlanWaiting() async throws {
        let failing = V094AutoUpdateBlocksUpgradeTests.Failing()
        var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
        let reads = try v094WrapStatus(&deps)
        let demo = deps.streamRunner
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, out in
            if args.first == "upgrade" {
                // Every read from here on fails, Auto-update's own included.
                reads.fail = true
                if let q = args.last, failing.contains(q.split(separator: "/").last.map(String.init) ?? q) {
                    out(Data("Error: simulated failure\n".utf8))
                    return 1
                }
            }
            return try await demo.stream("/usr/local/bin/brew", args, environment: [:], output: out)
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        let left = try #require(store.upgradable.first { $0.kind == .formula }?.name)
        failing.set([left])
        let before = store.upgradable
        try #require(before.count > 1)
        store.autoUpdate.settings.enabled = true
        _ = await store.autoUpdate.run(store: store, notifier: nil)
        #expect(await waitUntil { !store.isRefreshing })
        #expect(store.statusStale, "no read since the upgrades succeeded")

        // The plan, against the list on screen (from before the upgrades).
        store.upgradePlan = UpgradePlan(packages: before, classifier: store.deps.classifier)
        store.showUpgradeSheet = true
        store.confirmUpgradePlan()
        #expect(store.upgrade == nil, "nothing runs against the old list")
        #expect(store.upgradePlan != nil)
        #expect(await waitUntil { !store.isRefreshing })
        #expect(store.statusStale)

        reads.fail = false
        failing.set([])
        #expect(await store.refreshAfterChange())
        #expect(!store.statusStale)
        let plan = try #require(store.upgradePlan)
        #expect(plan.rows.map(\.package.name) == [left], "what Auto-update upgraded left the plan")
        #expect(plan.changedNote != nil)
        store.confirmUpgradePlan()
        let s = try #require(store.upgrade)
        #expect(s.items.map(\.package.name) == [left])
        #expect(await waitUntil { s.isFinished })
    }

    /// A read already running when the upgrades ended (begun before them)
    /// was joined: it gave the old versions, and Auto-update called its own
    /// upgrades "still outdated".
    @Test func autoUpdatesOwnReadStartsAfterItsUpgrades() async throws {
        var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
        let reads = try v094WrapStatus(&deps)
        let box = V094StoreBox()
        let demo = deps.streamRunner
        let once = V094AutoUpdateBlocksUpgradeTests.Failing()
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, out in
            if args.first == "upgrade", !once.contains("armed") {
                once.set(["armed"])
                // A window-to-the-front read begins before this upgrade.
                let hold = reads.arm()
                await MainActor.run {
                    guard let store = box.store else { return }
                    Task { await store.refresh(manual: false) }
                }
                await hold.sampled.wait()
            }
            return try await demo.stream("/usr/local/bin/brew", args, environment: [:], output: out)
        }
        let store = AppStore(deps: deps, settings: testSettings())
        box.store = store
        await store.start()
        defer { reads.releaseAll() }
        store.autoUpdate.settings.enabled = true
        let u = store.autoUpdate
        let task = Task { await u.run(store: store, notifier: nil) }
        // The upgrades are done and Auto-update waits on the read begun before them.
        try #require(await waitUntil { reads.held == 1 && u.isRunning && u.step == nil && store.refreshWaiters >= 1 })
        reads.releaseAll()
        let run = try #require(await task.value)
        #expect(!run.upgraded.isEmpty)
        #expect(!run.failed.contains { $0.detail == "still outdated after brew upgrade" })
        for item in run.upgraded {
            #expect(store.packages.first { $0.name == item.name }?.upgradeAvailable == false, "\(item.name)")
        }
        #expect(!store.statusStale)
    }
}

// MARK: MUST-FIX 2: the App Management prompt's run buttons recheck

// The upgrade plan became the App Management explainer; Continue and
// Skip Apps then ran the packages captured with it, after Auto-update had
// changed them, and Continue never asked which apps were open now.
@MainActor
struct V094AppManagementHandoffTests {
    func rig(gate: Bool = false, running: [RunningApp] = []) async throws -> AppStore {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appManagementGate = gate
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { _, _ in 0 }
        let settings = testSettings()
        InsightSettings(defaults: settings.defaults).includeSelfUpdatingApps = true
        let store = AppStore(deps: deps, settings: settings)
        store.autoUpdate.conditions = FixedConditions(ac: nil, idle: nil, apps: running)
        await store.start()
        return store
    }

    func chrome(_ store: AppStore) throws -> Package {
        try #require(store.packages.first { $0.name == "google-chrome" && $0.isManualUpgradeTarget })
    }

    /// Chrome opened while the explainer was up: Continue shows the plan
    /// naming it; that plan's Upgrade runs.
    @Test func continueNamesAnAppOpenNow() async throws {
        let store = try await rig(running: [V085RunningAppsTests.chrome])
        let c = try chrome(store)
        store.showAppManagementExplainer(packages: [c])
        store.appManagementNotNow()
        #expect(store.upgrade == nil, "the open app shows first")
        #expect(store.appManagementPrompt == nil)
        let plan = try #require(store.upgradePlan)
        #expect(plan.runningAppsToRun == ["Google Chrome"])
        #expect(plan.changedNote == nil)
        store.confirmUpgradePlan()
        let s = try #require(store.upgrade)
        #expect(s.items.map(\.package.id) == [c.id])
        #expect(await waitUntil { s.isFinished })
    }

    /// An app the plan already named doesn't stop Continue again.
    @Test func anAppThePlanNamedRunsAtOnce() async throws {
        let store = try await rig(gate: true, running: [V085RunningAppsTests.chrome])
        let c = try chrome(store)
        try #require(!store.settings.appManagementExplained)
        var plan = UpgradePlan(packages: [c], classifier: store.deps.classifier)
        plan.runningApps = store.runningCaskApps([c])
        try #require(plan.runningAppsToRun == ["Google Chrome"])
        store.upgradePlan = plan
        store.showUpgradeSheet = true
        store.confirmUpgradePlan()
        let prompt = try #require(store.appManagementPrompt, "the explainer took over")
        #expect(prompt.acknowledgedRunningApps == [c.id])
        store.appManagementContinue()
        #expect(store.appManagementPrompt == nil)
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.isFinished })
    }

    /// Auto-update upgraded the formula while the prompt was up: Skip Apps
    /// shows the plan without it instead of running it again.
    @Test func skipAppsShowsWhatChanged() async throws {
        let store = try await rig()
        let c = try chrome(store)
        let f = try #require(store.upgradable.first { $0.kind == .formula })
        store.showAppManagementExplainer(packages: [c, f])
        try #require(store.appManagementPrompt?.others.map(\.id) == [f.id])
        var r = try #require(store.report)
        let i = try #require(r.packages.firstIndex { $0.id == f.id })
        r.packages[i].installedVersion = f.currentVersion ?? "9"
        r.packages[i].installedVersions = [r.packages[i].installedVersion]
        r.packages[i].upgradeAvailable = false
        store.report = r
        store.appManagementSkipApps()
        #expect(store.upgrade == nil, "nothing it captured runs")
        let plan = try #require(store.upgradePlan)
        #expect(plan.rows.isEmpty)
        #expect(plan.changedNote != nil)
    }

    /// Continue (no relaunch) on targets Auto-update changed shows them.
    @Test func continueShowsChangedTargets() async throws {
        let store = try await rig()
        let fs = Array(store.upgradable.filter { $0.kind == .formula }.prefix(2))
        try #require(fs.count == 2)
        store.showAppManagementExplainer(packages: fs)
        var r = try #require(store.report)
        let i = try #require(r.packages.firstIndex { $0.id == fs[0].id })
        r.packages[i].upgradeAvailable = false
        store.report = r
        store.appManagementContinue()
        #expect(store.upgrade == nil)
        #expect(store.upgradePlan?.rows.map(\.package.id) == [fs[1].id])
        store.confirmUpgradePlan()
        #expect(store.upgrade?.items.map(\.package.id) == [fs[1].id])
    }

    /// The status is older than Auto-update's upgrades: the prompt waits.
    @Test func aStaleStatusKeepsThePrompt() async throws {
        let store = try await rig()
        let f = try #require(store.upgradable.first { $0.kind == .formula })
        store.showAppManagementExplainer(packages: [f])
        store.markStatusStale()
        store.appManagementContinue()
        #expect(store.appManagementPrompt != nil)
        #expect(store.upgrade == nil)
        #expect(await waitUntil { !store.statusStale && !store.isRefreshing })
        store.appManagementContinue()
        #expect(store.upgrade != nil)
    }
}

// MARK: MUST-FIX 3: a failed brew info doesn't offer a plain Install

@MainActor
struct V094FailedInfoInstallTests {
    @Test func anUnansweredLookupIsMarkedAndAsksFirst() async throws {
        let runner = CatalogInfoRunner()
        let client = makeClient(runner)
        let names = [("xz", "compression"), ("ghost", "compression too")]
        let indexer = FixedIndexer(entries: names.map { TapIndexEntry(kind: .formula, name: $0.0, tap: "homebrew/core", desc: $0.1) })
        let catalog = TapCatalog(client: client, detection: IntelbrewDetector.detect(coreOrigin: Intelbrew.coreRemote, sources: client.sources),
                                 indexer: indexer)
        let d = DiscoverStore(provider: catalog, debounce: .zero)
        await d.activate()
        d.query = "compression"
        await d.searchNow()
        await d.waitForDetails()
        let ghost = try #require(d.results.first { $0.name == "ghost" })
        let xz = try #require(d.results.first { $0.name == "xz" })
        #expect(ghost.detailsLoaded && ghost.detailsFailed)
        #expect(ghost.bottle == .unknown)
        #expect(xz.detailsLoaded && !xz.detailsFailed)
        let warning = { (e: CatalogEntry) in CompileClassifier().installWarning(e) }
        let ghostInstall = ContextMenus.discoverInstall(ghost, compileWarning: warning(ghost), busy: false)
        #expect(ghostInstall.action == .install(confirmCompile: true), "no plain Install without a bottle answer")
        #expect(ghostInstall.title == "Install ghost (compiles)…")
        #expect(ContextMenus.discoverInstall(xz, compileWarning: warning(xz), busy: false).action == .install(confirmCompile: false))
    }

    /// brew info failing outright marks every row failed.
    @Test func aFailedLookupIsMarkedFailed() async throws {
        let runner = FakeInfoRunner(log: CallLog(), info: Data())
        runner.failInfo = true
        let client = makeIsolatedClient(runner)
        let catalog = TapCatalog(client: client, detection: IntelbrewDetector.detect(coreOrigin: Intelbrew.coreRemote, sources: client.sources),
                                 indexer: FixedIndexer(entries: []))
        let e = CatalogEntry(kind: .formula, name: "foo", fullName: "foo", tap: "homebrew/core", desc: nil, bottle: .unknown, detailsLoaded: false)
        let out = await catalog.details([e])
        #expect(out.count == 1)
        #expect(out[0].detailsLoaded && out[0].detailsFailed && out[0].bottle == .unknown)
        #expect(ContextMenus.discover(out[0], installed: false, compileWarning: nil, busy: false).contains {
            if case .item(let m) = $0 { return m.id == "install" && m.action == .install(confirmCompile: true) }
            return false
        })
    }

    /// A cask's unknown bottle isn't a compile question.
    @Test func casksAreUnaffected() {
        let c = CatalogEntry(kind: .cask, name: "foo", fullName: "foo", tap: "homebrew/cask", desc: nil, bottle: .cask)
        #expect(ContextMenus.discoverInstall(c, compileWarning: nil, busy: false).action == .install(confirmCompile: false))
    }
}

// MARK: MUST-FIX 4: Clean Up's preview follows the inventory

// With "Keep the previous version" on, the sheet kept the formulae with
// two versions when it opened. Auto-update then left a second version of
// another one; Clean Up ran the old list and removed it, unseen.
@MainActor
struct V094CleanupFollowsInventoryTests {
    func rig() async throws -> (AppStore, Package) {
        var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { _, _ in 0 }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        store.restorePoints.settings.keepPreviousVersion = true
        store.openCleanup()
        let c = try #require(store.cleanup)
        #expect(await waitUntil { c.phase == .ready && !c.measuringCache })
        let f = try #require(store.packages.first { $0.kind == .formula && Set($0.installedVersions).count == 1 && !c.kept.contains($0.name) })
        return (store, f)
    }

    /// A second version of `f` on disk (an upgrade kept the old one).
    func secondKeg(_ store: AppStore, _ f: Package) throws {
        var r = try #require(store.report)
        let i = try #require(r.packages.firstIndex { $0.id == f.id })
        r.packages[i].installedVersions = ["0.0.1", f.installedVersion]
        store.report = r
    }

    @Test func anInventoryChangeRebuildsTheOpenPreview() async throws {
        let (store, f) = try await rig()
        let old = try #require(store.cleanup)
        try secondKeg(store, f)
        let fresh = try #require(store.cleanup)
        #expect(fresh !== old)
        #expect(fresh.kept.contains(f.name))
        #expect(fresh.extraEnvironment[CleanupKeep.key]?.contains(f.name) == true)
        #expect(await waitUntil { fresh.phase == .ready })
        store.startCleanup()
        #expect(store.upgrade?.action == .cleanup)
    }

    /// Clean Up itself checks too: a preview of another inventory shows
    /// again, worked out afresh, instead of running.
    @Test func cleanUpRefusesAnOutdatedPreview() async throws {
        let (store, f) = try await rig()
        let old = try #require(store.cleanup)
        store.showCleanupSheet = false
        try secondKeg(store, f)
        #expect(store.cleanup === old, "nothing on screen to rebuild")
        store.showCleanupSheet = true
        store.startCleanup()
        #expect(store.upgrade == nil)
        #expect(store.showCleanupSheet)
        let fresh = try #require(store.cleanup)
        #expect(fresh !== old && fresh.kept.contains(f.name))
        #expect(await waitUntil { fresh.phase == .ready })
        store.startCleanup()
        #expect(store.upgrade?.action == .cleanup)
    }

    @Test func aStaleStatusWaits() async throws {
        let (store, _) = try await rig()
        store.markStatusStale()
        store.startCleanup()
        #expect(store.upgrade == nil)
        #expect(store.showCleanupSheet)
        #expect(await waitUntil { !store.statusStale && !store.isRefreshing })
        let c = try #require(store.cleanup)
        #expect(await waitUntil { c.phase == .ready })
        store.startCleanup()
        #expect(store.upgrade?.action == .cleanup)
    }

    @Test func theSheetWaitsForAFreshRead() throws {
        let activity = try v094Source("TankardApp/ActivitySheets.swift")
        #expect(activity.components(separatedBy: ".disabled(cleanup.phase != .ready || store.statusStale ||").count - 1 == 2)
        #expect(activity.contains(".disabled(plan.toRun.isEmpty || store.autoUpdate.isRunning || store.statusStale)"))
    }
}

// MARK: SHOULD-FIX 1: a qualified name ranks its own entry first

struct V094QualifiedCollisionTests {
    static let entries = [
        CatalogEntry(kind: .formula, name: "wget", fullName: "wget", tap: "homebrew/core", desc: nil, bottle: .forThisMac),
        CatalogEntry(kind: .cask, name: "wget", fullName: "wget", tap: "homebrew/cask", desc: nil, bottle: .cask),
        CatalogEntry(kind: .formula, name: "wget", fullName: "aaa/tools/wget", tap: "aaa/tools", desc: nil, bottle: .forThisMac),
    ]

    @Test func theTapAndKindAskedForComeFirst() {
        #expect(CatalogSearch.search("homebrew/core/wget", in: Self.entries).first?.id == Self.entries[0].id)
        #expect(CatalogSearch.search("homebrew/cask/wget", in: Self.entries).first?.id == Self.entries[1].id)
        #expect(CatalogSearch.search("brew install --cask homebrew/cask/wget", in: Self.entries).first?.id == Self.entries[1].id)
        for e in Self.entries {
            #expect(CatalogSearch.search(e.installDisplay, in: Self.entries).first?.id == e.id, "\(e.installDisplay)")
        }
    }

    /// Popularity and bottles break ties only within a tier.
    @Test func popularityDoesntOutrankIt() {
        let pop = [Self.entries[0].id: 1, Self.entries[1].id: 1_000_000, Self.entries[2].id: 1_000_000]
        #expect(CatalogSearch.search("homebrew/core/wget", in: Self.entries, preferBottled: true, popularity: pop).first?.id == Self.entries[0].id)
        let pop2 = [Self.entries[0].id: 1_000_000]
        #expect(CatalogSearch.search("homebrew/cask/wget", in: Self.entries, popularity: pop2).first?.id == Self.entries[1].id)
    }

    /// A plain name still ranks as before (formula before cask on a tie).
    @Test func aPlainNameIsUnchanged() {
        #expect(CatalogSearch.search("wget", in: Self.entries).first?.id == Self.entries[0].id)
    }
}

// MARK: SHOULD-FIX 2: a slow service action's problem stays with it

@MainActor
struct V094ServiceProblemAfterSwitchTests {
    @Test func aProblemArrivingAfterAnotherRowIsSelectedStaysOff() async throws {
        let gate = Latch()
        var deps = Demo.dependencies(.intelbrew, pace: 0)
        let demo = deps.streamRunner
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, out in
            if args.first == "services", args.count > 1, args[1] == "start" {
                await gate.wait()
                out(Data("Error: simulated start failure\n".utf8))
                return 1
            }
            return try await demo.stream("/usr/local/bin/brew", args, environment: [:], output: out)
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        defer { gate.release() }
        let services = try #require(store.openServices())
        await services.load()
        let mine = services.services.filter { !services.needsSudo($0) }
        try #require(mine.count >= 2, "two of the user's own services")
        let (a, b) = (mine[0], mine[1])
        services.selection = a.id
        let action = Task { await services.perform(.start, on: a, store: store) }
        try #require(await waitUntil { store.quickAction?.hasPrefix("brew services start") == true })
        services.selection = b.id
        gate.release()
        await action.value
        #expect(services.actionError == nil, "\(a.name)'s problem isn't shown under \(b.name)")

        // Without the switch it shows under its own service.
        services.selection = a.id
        await services.perform(.start, on: a, store: store)
        #expect(services.actionError?.title.contains(a.name) == true)
    }
}

// MARK: SHOULD-FIX 3: Trust reads the status afresh

// The re-read after Trust / Stop Trusting could join a read begun before
// the change, which kept the package's old readability.
@MainActor
struct V094TrustFreshReadTests {
    final class Trust: @unchecked Sendable {
        private let lock = NSLock()
        private var _on = false
        var on: Bool {
            get { lock.withLock { _on } }
            set { lock.withLock { _on = newValue } }
        }
    }

    nonisolated static let tap = "mull-project/mull"

    /// brew's answer with mull readable (trusted) or left out (untrusted:
    /// the keg scan then finds it, unreadable).
    nonisolated static func info(_ base: Data, trusted: Bool) -> Data {
        guard trusted, var root = try? JSONSerialization.jsonObject(with: base) as? [String: Any],
              var formulae = root["formulae"] as? [[String: Any]], var mull = formulae.first else { return base }
        mull["name"] = "mull"
        mull["full_name"] = "\(tap)/mull"
        mull["tap"] = tap
        mull["outdated"] = false
        formulae.append(mull)
        root["formulae"] = formulae
        return (try? JSONSerialization.data(withJSONObject: root)) ?? base
    }

    func rig() async throws -> (AppStore, V094StatusRunner, Trust) {
        let trust = Trust()
        var deps = Demo.dependencies(.arm64, pace: 0)
        let reads = try v094WrapStatus(&deps) { client in
            client.unreadableScan = { info in
                info.formulae.contains { $0.name == "mull" } ? []
                    : [UnreadableKegs.row(kind: .formula, name: "mull", tap: Self.tap, versions: ["1.0"], requested: true, poured: true, time: nil)]
            }
        }
        reads.transform = { Self.info($0, trusted: trust.on) }
        let demo = deps.streamRunner
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, out in
            if args.first == "trust" || args.first == "untrust", args.last == Self.tap { trust.on = args.first == "trust" }
            return try await demo.stream("/opt/homebrew/bin/brew", args, environment: [:], output: out)
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        store.openTaps()
        #expect(await waitUntil { store.taps.phase == .ready })
        return (store, reads, trust)
    }

    func mull(_ store: AppStore) -> Package? { store.packages.first { $0.name == "mull" } }

    /// Trust or Stop Trusting with a read already running (begun before it).
    func change(_ store: AppStore, _ reads: V094StatusRunner, to trusted: Bool) async throws {
        let tap = try #require(store.taps.taps.first { $0.name == Self.tap })
        try #require((tap.trusted ?? false) != trusted)
        let hold = reads.arm()
        let reading = Task { await store.refresh(manual: false) }
        await hold.sampled.wait()
        let done = store.refreshesCompleted
        store.taps.requestTrust(tap)
        store.confirmTrustTap()
        // The change is made and its re-read waits on the old read.
        try #require(await waitUntil { store.taps.taps.first { $0.name == Self.tap }?.trusted == trusted && store.refreshWaiters >= 1 })
        hold.gate.release()
        await reading.value
        #expect(await waitUntil { store.refreshesCompleted >= done + 2 && !store.isRefreshing }, "a read after the change")
    }

    @Test func bothDirectionsReadTheNewState() async throws {
        let (store, reads, trust) = try await rig()
        defer { reads.releaseAll() }
        #expect(mull(store)?.unreadable != nil, "untrusted: can't be read")
        try await change(store, reads, to: true)
        #expect(trust.on)
        #expect(mull(store) != nil && mull(store)?.unreadable == nil, "trusted: readable")
        #expect(store.error == nil)
        try await change(store, reads, to: false)
        #expect(!trust.on)
        #expect(mull(store)?.unreadable != nil, "untrusted again: can't be read")
        #expect(store.error == nil)
    }
}

// MARK: SHOULD-FIX 4: the self-updating toggle on a cold launch

@MainActor
struct V094GreedyColdLaunchTests {
    @Test func turningItOnDuringTheFirstReadAsksBrew() async throws {
        let log = CallLog()
        let info = FakeInfoRunner(log: log, info: demoIntelInfo())
        let gated = V094GatedInfoRunner(info)
        let client = makeIsolatedClient(gated)
        // No cache: no report until the first read ends.
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: FakeStreamRunner(log: log) { _, _ in 0 },
                                                         cache: nil, logURL: nil), settings: testSettings())
        defer { gated.gate.release() }
        try #require(!store.insights.settings.includeSelfUpdatingApps)
        gated.arm()
        let launch = Task { await store.start() }
        // The first read has decided (no --greedy) and waits on brew info.
        try #require(await waitUntil { gated.entered == 1 && store.isRefreshing })
        try #require(store.report == nil)
        store.insights.settings.includeSelfUpdatingApps = true
        let followUp = try #require(store.greedyFollowUp, "a follow-up with no report yet")
        // It joined the running read before that read is let go.
        try #require(await waitUntil { store.refreshWaiters >= 1 })
        gated.gate.release()
        await launch.value
        await followUp.value
        #expect(store.lastReadAskedGreedy)
        #expect(info.insightLog.calls.contains(BrewClient.greedyOutdatedArguments))
    }
}

// MARK: SHOULD-FIX 5: a window opened on Services or Discover

struct V094TabInitialStateTests {
    @Test func theTabsStoreIsMadeWhenTheWindowOpens() throws {
        let view = try v094Source("TankardApp/ContentView.swift")
        #expect(view.contains(".onAppear { if store.report != nil { openSelectedTabStore() } }"))
        let helper = try #require(view.range(of: "private func openSelectedTabStore() {"))
        let body = view[helper.upperBound...].prefix(200)
        #expect(body.contains("if store.tab == .discover { openDiscover() }"))
        #expect(body.contains("if store.tab == .services { store.openServices() }"))
    }
}
