import Foundation
import os
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.8.10 fixes to Replace with Homebrew's Version:
// - a failed run never deletes the copy unless it is back in place; a
//   half-deleted bundle (Stop Now during brew's delete), one without its
//   executable, or another app at the path is moved aside as
//   "<name>.partial" and the copy goes back;
// - only brew's exit 0 with a whole app of the cask's version deletes it;
// - the app is read again right before the copy (it may have updated
//   itself), and checked for running again right before brew starts;
// - only a cask that installs exactly one app, and never a build-number
//   downgrade;
// - at launch, a copy whose app's path is empty is put back.

@MainActor
struct V0810ReplaceFixTests {
    final class Dir {
        let url: URL
        let apps: URL
        let root: URL
        init() {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-replace-fix-\(UUID().uuidString)")
            apps = url.appendingPathComponent("Applications")
            root = url.appendingPathComponent("backups")
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        var app: URL { apps.appendingPathComponent("Foo.app") }
        func items(_ dir: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() }
    }

    // MARK: - finish, on disk

    /// Stop Now during brew's `rm -rf`: the bundle is there but half gone.
    @Test func halfDeletedBundleIsMovedAsideAndTheCopyRestored() throws {
        let d = Dir(), fm = FileManager.default
        try FakeBundle.make(d.app, version: "1.0")
        let live = AppReplaceSafety.live(root: d.root)
        let copy = try live.backup(d.app.path)
        let dir = (copy as NSString).deletingLastPathComponent
        // brew got as far as Info.plist.
        try fm.removeItem(at: d.app.appendingPathComponent("Contents/Info.plist"))
        let outcome = live.finish(d.app.path, copy, false, "2.0")
        let partial = (dir as NSString).appendingPathComponent("Foo.app.partial")
        #expect(outcome == .restoredMovingAside(partial: partial))
        #expect(FakeBundle.version(d.app) == "1.0")
        #expect(fm.fileExists(atPath: (partial as NSString).appendingPathComponent("Contents/MacOS/Foo")))
        // The copy's folder stays (with what brew left), the copy itself is back.
        #expect(!fm.fileExists(atPath: copy))
        // A later launch lists the partial and leaves it.
        #expect(live.leftovers() == [partial])
        #expect(live.recoverLeftover(partial) == .kept)
        #expect(fm.fileExists(atPath: partial))
    }

    @Test func bundleWithoutItsExecutableOrAnotherAppIsMovedAside() throws {
        let d = Dir(), fm = FileManager.default
        let live = AppReplaceSafety.live(root: d.root)

        // The executable gone (the plist still there).
        try FakeBundle.make(d.app, version: "1.0")
        var copy = try live.backup(d.app.path)
        try fm.removeItem(at: d.app.appendingPathComponent("Contents/MacOS/Foo"))
        guard case .restoredMovingAside(let p1) = live.finish(d.app.path, copy, false, "2.0") else {
            Issue.record("not moved aside"); return
        }
        #expect(FakeBundle.version(d.app) == "1.0" && fm.fileExists(atPath: d.app.appendingPathComponent("Contents/MacOS/Foo").path))
        #expect(p1.hasSuffix("/Foo.app.partial"))

        // A different app (another bundle id) at the path.
        copy = try live.backup(d.app.path)
        try FakeBundle.make(d.app, id: "com.other.Thing", version: "9.0")
        guard case .restoredMovingAside(let p2) = live.finish(d.app.path, copy, false, "2.0") else {
            Issue.record("not moved aside"); return
        }
        #expect(FakeBundle.version(d.app) == "1.0" && FakeBundle.version(URL(fileURLWithPath: p2)) == "9.0")

        // A plain file at the path.
        copy = try live.backup(d.app.path)
        try fm.removeItem(at: d.app)
        try Data("x".utf8).write(to: d.app)
        guard case .restoredMovingAside = live.finish(d.app.path, copy, false, "2.0") else {
            Issue.record("not moved aside"); return
        }
        #expect(FakeBundle.version(d.app) == "1.0")
    }

    /// A failed run with the same app still whole: both stay.
    @Test func failedRunWithTheAppWholeKeepsTheCopy() throws {
        let d = Dir(), fm = FileManager.default
        try FakeBundle.make(d.app, version: "1.0")
        let live = AppReplaceSafety.live(root: d.root)
        let copy = try live.backup(d.app.path)
        #expect(live.finish(d.app.path, copy, false, "2.0") == .kept(backup: copy))
        #expect(fm.fileExists(atPath: copy) && FakeBundle.version(d.app) == "1.0")
        // A launch later: the app's path is taken, so it is only listed.
        #expect(live.recoverLeftover(copy) == .kept && fm.fileExists(atPath: copy))
    }

    /// brew's exit 0 isn't enough: the app must be whole and the cask's version.
    @Test func successNeedsAWholeAppOfTheCasksVersion() throws {
        let d = Dir(), fm = FileManager.default
        let live = AppReplaceSafety.live(root: d.root)
        try FakeBundle.make(d.app, version: "1.0")

        // Exit 0, but the app at the path is still 1.0: kept.
        var copy = try live.backup(d.app.path)
        #expect(live.finish(d.app.path, copy, true, "2.0") == .kept(backup: copy))
        #expect(fm.fileExists(atPath: copy))

        // Exit 0, and the bundle is broken: the copy goes back.
        copy = try live.backup(d.app.path)
        try FakeBundle.make(d.app, version: "2.0", executable: false)
        guard case .restoredMovingAside = live.finish(d.app.path, copy, true, "2.0") else {
            Issue.record("not restored"); return
        }
        #expect(FakeBundle.version(d.app) == "1.0")

        // Exit 0, 2.0.0 for a cask 2.0 (brew's ordering), or the build
        // number as the cask's version: discarded.
        copy = try live.backup(d.app.path)
        try FakeBundle.make(d.app, version: "2.0.0")
        #expect(live.finish(d.app.path, copy, true, "2.0") == .discarded)
        #expect(!fm.fileExists(atPath: copy))
        copy = try live.backup(d.app.path)
        try FakeBundle.make(d.app, version: "2.1", build: "210")
        #expect(live.finish(d.app.path, copy, true, "210") == .discarded)
    }

    // MARK: - leftovers at launch

    @Test func leftoverIsPutBackOnlyWhenItsPathIsEmpty() throws {
        let d = Dir(), fm = FileManager.default
        try FakeBundle.make(d.app, version: "1.0")
        let live = AppReplaceSafety.live(root: d.root)

        // Tankard quit after brew removed the app: the path is empty.
        let copy = try live.backup(d.app.path)
        try fm.removeItem(at: d.app)
        #expect(live.recoverLeftover(copy) == .restored(to: d.app.path))
        #expect(FakeBundle.version(d.app) == "1.0")
        #expect(d.items(d.root.path).isEmpty)

        // The path is taken (the new app, or the old one): kept.
        let copy2 = try live.backup(d.app.path)
        #expect(live.recoverLeftover(copy2) == .kept)
        #expect(fm.fileExists(atPath: copy2))

        // No record of where it came from (a copy cut short, or made by an
        // earlier build): kept, even with the path empty.
        let dir2 = (copy2 as NSString).deletingLastPathComponent
        try fm.removeItem(atPath: (dir2 as NSString).appendingPathComponent(".origin"))
        try fm.removeItem(at: d.app)
        #expect(live.recoverLeftover(copy2) == .kept)
        #expect(fm.fileExists(atPath: copy2) && !fm.fileExists(atPath: d.app.path))

        // A copy that isn't a whole bundle: kept.
        try FakeBundle.make(d.app, version: "1.0")
        let copy3 = try live.backup(d.app.path)
        try fm.removeItem(at: d.app)
        try fm.removeItem(atPath: (copy3 as NSString).appendingPathComponent("Contents/Info.plist"))
        #expect(live.recoverLeftover(copy3) == .kept)
        #expect(fm.fileExists(atPath: copy3))
    }

    @Test func launchPutsBackALeftoverAndLogsTheRest() async throws {
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        let safety = AppReplaceSafety(
            backup: { _ in "/tmp/x" },
            finish: { _, _, _, _ in calls.withLock { $0.append("finish") }; return .discarded },
            discard: { _ in calls.withLock { $0.append("discard") } },
            leftovers: { ["/c/A/Foo.app", "/c/B/Bar.app"] },
            recoverLeftover: { p in
                calls.withLock { $0.append("recover \(p)") }
                return p.hasSuffix("Foo.app") ? .restored(to: "/Applications/Foo.app") : .kept
            })
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appReplaceSafety = safety
        let store = AppStore(deps: deps)
        await store.start()
        #expect(await waitUntil { calls.withLock { $0.contains("recover /c/B/Bar.app") } })
        #expect(!calls.withLock { $0.contains("finish") || $0.contains("discard") })
    }

    // MARK: - the run

    /// Records the run, with an app on disk that reads as `info`.
    final class Recorder: Sendable {
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        let info: OSAllocatedUnfairLock<AppReplaceSafety.BundleInfo?>
        let onBackup: @Sendable () -> Void
        init(info: AppReplaceSafety.BundleInfo?, onBackup: @escaping @Sendable () -> Void = {}) {
            self.info = OSAllocatedUnfairLock(initialState: info)
            self.onBackup = onBackup
        }
        var safety: AppReplaceSafety {
            AppReplaceSafety(
                backup: { [self] p in calls.withLock { $0.append("backup") }; onBackup(); return "/tmp/b/\((p as NSString).lastPathComponent)" },
                finish: { [self] _, _, ok, v in calls.withLock { $0.append("finish \(ok) \(v)") }; return ok ? .discarded : .restored },
                discard: { [self] _ in calls.withLock { $0.append("discard") } },
                readApp: { [self] _ in calls.withLock { $0.append("read") }; return info.withLock { $0 } })
        }
    }

    func demo(_ r: Recorder) async throws -> AppStore {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appReplaceSafety = r.safety
        let store = AppStore(deps: deps)
        store.settings.appManagementExplained = true
        await store.start()
        store.openAdopt()
        #expect(await waitUntil { store.adopt.phase == .ready })
        return store
    }

    func plan(_ store: AppStore) throws -> ReplaceAppPlan {
        let row = try #require(store.adopt.rows(.needsUpdate).first { $0.app.displayName == "Audacity" })
        let plan = try #require(store.adopt.replacePlan(row))
        store.closeToolSheet()
        return plan
    }

    static let audacity = AppReplaceSafety.BundleInfo(bundleID: "org.audacityteam.audacity4", shortVersion: "4.0.1", bundleVersion: "4.0.1")

    @Test func unchangedAppRuns() async throws {
        let r = Recorder(info: Self.audacity)
        let store = try await demo(r)
        let p = try plan(store)
        #expect(p.bundleVersion == "4.0.1")
        #expect(await store.startReplace(p))
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        #expect(await waitUntil { r.calls.withLock { $0.count } == 3 })
        #expect(r.calls.withLock { $0 } == ["read", "backup", "finish true 4.0.2"])
    }

    /// The app updated itself since the scan: nothing is copied, brew doesn't run.
    @Test func anAppThatChangedSinceTheScanIsNotReplaced() async throws {
        let r = Recorder(info: .init(bundleID: "org.audacityteam.audacity4", shortVersion: "4.1.0", bundleVersion: "4.1.0"))
        let store = try await demo(r)
        let p = try plan(store)
        #expect(await !store.startReplace(p))
        #expect(store.upgrade == nil)
        #expect(r.calls.withLock { $0 } == ["read"])
        #expect(store.busyNotice?.contains("Audacity changed since the scan (it is now version 4.1.0)") == true)

        // Only its build changed (still older than the cask): changed all the same.
        r.info.withLock { $0 = .init(bundleID: "org.audacityteam.audacity4", shortVersion: "4.0.1", bundleVersion: "4.0.1.7") }
        #expect(await !store.startReplace(p))
        // Another app at the path now.
        r.info.withLock { $0 = .init(bundleID: "com.other.app", shortVersion: "4.0.1", bundleVersion: "4.0.1") }
        #expect(await !store.startReplace(p))
        // Its Info.plist can't be read.
        r.info.withLock { $0 = nil }
        #expect(await !store.startReplace(p))
        #expect(store.busyNotice?.contains("couldn't read Audacity's version") == true)
        #expect(!r.calls.withLock { $0.contains("backup") } && store.upgrade == nil)
    }

    @Test func changedNoteRules() {
        let p = ReplaceAppPlan(token: "foo", qualifiedName: "homebrew/cask/foo", appName: "Foo", appPath: "/Applications/Foo.app",
                               bundleID: "com.foo.Foo", installedVersion: "2.0", caskVersion: "2.1", bundleVersion: "200")
        #expect(p.changedNote(now: .init(bundleID: "COM.foo.foo", shortVersion: "2.0", bundleVersion: "200")) == nil)
        #expect(p.changedNote(now: .init(bundleID: "com.foo.Foo", shortVersion: "2.2", bundleVersion: "220")) != nil)
        #expect(p.changedNote(now: .init(bundleID: "com.foo.Foo", shortVersion: "2.1", bundleVersion: "210")) != nil)
        #expect(p.changedNote(now: nil) != nil)
    }

    /// Opened while the copy was made: the copy is dropped, brew doesn't run.
    /// Running apps that change from any thread (the copy runs detached).
    final class OpenApps: AutoUpdateConditions {
        let apps = OSAllocatedUnfairLock<[RunningApp]>(initialState: [])
        func onACPower() -> Bool? { nil }
        func idleSeconds() -> TimeInterval? { nil }
        func runningApps() -> [RunningApp] { apps.withLock { $0 } }
    }

    @Test func appOpenedDuringTheCopyStopsTheRun() async throws {
        let open = OpenApps()
        let lock = open.apps
        let r = Recorder(info: Self.audacity, onBackup: {
            lock.withLock { $0 = [RunningApp(path: "/Applications/Audacity 4.app", bundleID: nil)] }
        })
        let store = try await demo(r)
        store.autoUpdate.conditions = open
        let p = try plan(store)
        #expect(await !store.startReplace(p))
        #expect(store.upgrade == nil)
        #expect(r.calls.withLock { $0 } == ["read", "backup", "discard"])
        #expect(store.busyNotice?.contains("Audacity is open. Quit it first") == true)
    }

    // MARK: - when it is offered

    @Test func notOfferedForMoreThanOneAppOrABuildNumberDowngrade() async throws {
        func store(_ c: AdoptCask, _ app: InstalledApp) -> (AdoptStore, AdoptRow?) {
            let a = AdoptStore()
            a.apply(AdoptInput(index: AdoptIndex(casks: [c]), apps: [app], source: "test"))
            return (a, a.scan.rows.first)
        }
        let foo = InstalledApp(path: "/Applications/Foo.app", root: "/Applications", relativePath: "Foo.app", bundleID: "com.foo.Foo",
                               shortVersion: "2.0", bundleVersion: "200")
        let one: [BrewInfoJSON.Cask.AdoptArtifacts.App] = [.init(source: "Foo.app", target: "/Applications/Foo.app")]

        // short 2.0, build 200, cask 199.
        let (a1, r1) = store(AdoptCask(token: "foo", version: "199", apps: one, bundleIDs: ["com.foo.foo"]), foo)
        let row1 = try #require(r1)
        #expect(a1.group(row1) == .needsUpdate && a1.confidence(row1) == .high)
        #expect(a1.replaceEligibility(row1) == .cantTell && !a1.offersReplace(row1) && a1.replacePlan(row1) == nil)

        // A normal update with the same cask shape: offered.
        let hb = InstalledApp(path: "/Applications/Foo.app", root: "/Applications", relativePath: "Foo.app", bundleID: "com.foo.Foo",
                              shortVersion: "1.13.1", bundleVersion: "15")
        let (a2, r2) = store(AdoptCask(token: "foo", version: "1.13.2", apps: one, bundleIDs: ["com.foo.foo"]), hb)
        let row2 = try #require(r2)
        #expect(a2.offersReplace(row2) && a2.replacePlan(row2)?.caskVersion == "1.13.2")

        // Two apps (karabiner-elements' shape): not offered.
        let two = one + [.init(source: "Foo Helper.app", target: "/Applications/Foo Helper.app")]
        let (a3, r3) = store(AdoptCask(token: "foo", version: "1.13.2", apps: two, bundleIDs: ["com.foo.foo"]), hb)
        let row3 = try #require(r3)
        #expect(a3.group(row3) == .needsUpdate && a3.confidence(row3) == .high && !a3.offersReplace(row3))

        // An app and a binary: not offered.
        let (a4, r4) = store(AdoptCask(token: "foo", version: "1.13.2", apps: one, bundleIDs: ["com.foo.foo"],
                                       contentKinds: ["app", "binary"]), hb)
        #expect(!a4.offersReplace(try #require(r4)))

        // The demo: GIMP's cask also installs a command wrapper; Audacity's only the app.
        let deps = Demo.dependencies(.arm64, pace: 0)
        let demo = AppStore(deps: deps)
        await demo.start()
        demo.openAdopt()
        #expect(await waitUntil { demo.adopt.phase == .ready })
        let gimp = try #require(demo.adopt.rows(.needsUpdate).first { $0.app.displayName == "GIMP" })
        let aud = try #require(demo.adopt.rows(.needsUpdate).first { $0.app.displayName == "Audacity" })
        #expect(!demo.adopt.offersReplace(gimp) && demo.adopt.offersReplace(aud))
    }
}
