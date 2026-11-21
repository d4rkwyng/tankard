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
// - the app is read again right before the copy and again after it (it
//   may have updated itself), and checked for running again right before
//   brew starts;
// - only a cask that installs exactly one app, and never a build-number
//   downgrade (2.0 / build 200 / cask 199);
// - at launch, leftover copies are listed and one notice is shown. Nothing
//   is moved. A finished run deletes `.origin`.

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
        // A later launch lists the partial and leaves it. `.origin` is gone:
        // this run finished.
        #expect(live.leftovers() == [partial])
        #expect(!fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".origin")))
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

    /// brew exited 1 after installing: the app is whole and is the cask's
    /// version. The copy stays (the run failed). The note says so, and does
    /// not say the app is as it was or that Homebrew is busy.
    @Test func failedRunWithTheAppNowAtTheCaskVersionKeepsTheCopyAndSaysSo() async throws {
        let d = Dir(), fm = FileManager.default
        try FakeBundle.make(d.app, version: "1.0")
        let live = AppReplaceSafety.live(root: d.root)
        let copy = try live.backup(d.app.path)
        try FakeBundle.make(d.app, version: "2.0")
        #expect(live.finish(d.app.path, copy, false, "2.0") == .replacedDespiteError(backup: copy))
        #expect(fm.fileExists(atPath: copy))
        #expect(FakeBundle.version(URL(fileURLWithPath: copy)) == "1.0")
        #expect(FakeBundle.version(d.app) == "2.0")
        #expect(!fm.fileExists(atPath: (copy as NSString).deletingLastPathComponent + "/.origin"))

        // The same isVersion rule as a successful run: 2.0.0 is cask 2.0.
        try FakeBundle.make(d.app, version: "1.0")
        let copy2 = try live.backup(d.app.path)
        try FakeBundle.make(d.app, version: "2.0.0")
        #expect(live.finish(d.app.path, copy2, false, "2.0") == .replacedDespiteError(backup: copy2))
        #expect(fm.fileExists(atPath: copy2) && FakeBundle.version(URL(fileURLWithPath: copy2)) == "1.0")

        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        let info = Self.audacity
        var deps = Demo.dependencies(.arm64, pace: 0)
        let runner = LockRunner(deps.streamRunner)
        deps.streamRunner = runner
        deps.lockWait = BrewLockWait(interval: .milliseconds(20), limit: .milliseconds(300), maxAttempts: 5, holders: { _ in
            ["99 brew install"]
        })
        deps.appReplaceSafety = AppReplaceSafety(
            backup: { p in calls.withLock { $0.append("backup") }; return "/tmp/b/\((p as NSString).lastPathComponent)" },
            finish: { _, backup, ok, v in
                calls.withLock { $0.append("finish \(ok) \(v)") }
                return ok ? .discarded : .replacedDespiteError(backup: backup)
            },
            readApp: { _ in calls.withLock { $0.append("read") }; return info })
        let store = AppStore(deps: deps)
        store.settings.appManagementExplained = true
        await store.start()
        store.openAdopt()
        #expect(await waitUntil { store.adopt.phase == .ready })
        let p = try plan(store)
        #expect(await store.startReplace(p))
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        #expect(calls.withLock { $0.contains("finish false 4.0.2") })
        let lines = store.upgrade?.log.lines.joined(separator: "\n") ?? ""
        #expect(lines.contains("Audacity was updated to 4.0.2, but Homebrew reported an error. Tankard kept a copy of the old version at /tmp/b/Audacity 4.app."))
        #expect(!lines.contains("Homebrew is busy; try again in a moment."))
        #expect(!lines.contains("wasn't replaced"))
        #expect(!lines.contains("it is as it was"))
    }

    /// brew exited 1 after the app was already the cask's version. The sheet
    /// counts the step as replaced, with a warning, and does not offer a retry.
    @Test func replacedDespiteErrorCountsAsReplacedWithAWarning() async throws {
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        let info = Self.audacity
        var deps = Demo.dependencies(.arm64, pace: 0)
        let runner = LockRunner(deps.streamRunner)
        deps.streamRunner = runner
        deps.lockWait = BrewLockWait(interval: .milliseconds(20), limit: .milliseconds(300), maxAttempts: 5, holders: { _ in
            ["99 brew install"]
        })
        deps.appReplaceSafety = AppReplaceSafety(
            backup: { p in calls.withLock { $0.append("backup") }; return "/tmp/b/\((p as NSString).lastPathComponent)" },
            finish: { _, backup, ok, v in
                calls.withLock { $0.append("finish \(ok) \(v)") }
                return ok ? .discarded : .replacedDespiteError(backup: backup)
            },
            readApp: { _ in calls.withLock { $0.append("read") }; return info })
        let store = AppStore(deps: deps)
        store.settings.appManagementExplained = true
        await store.start()
        store.openAdopt()
        #expect(await waitUntil { store.adopt.phase == .ready })
        let p = try plan(store)
        #expect(await store.startReplace(p))
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        let session = try #require(store.upgrade)
        let item = try #require(session.items.first)
        #expect(item.state == .done)
        #expect(session.replacedDespiteError == [item.id])
        #expect(session.failureKinds.isEmpty)
        #expect(session.failureKindByItem[item.id] == nil)
        #expect(session.succeededCount == 1)
        #expect(session.failedItems.isEmpty)
        #expect(session.hasProblems)
        #expect(!session.finishedCleanly)
        #expect(session.title == "Replace finished with a warning")
        #expect(session.subtitle == "1 cask")
        #expect(session.statusLine == "1 replaced")
        #expect(session.nextStep == nil)
        let lines = session.log.lines.joined(separator: "\n")
        #expect(lines.contains("Audacity was updated to 4.0.2, but Homebrew reported an error. Tankard kept a copy of the old version at /tmp/b/Audacity 4.app."))
        #expect(!lines.contains("Another Homebrew command is running"))
        #expect(!lines.contains("Retry once it has finished"))
        #expect(!lines.contains("then retry"))
        #expect(!lines.contains("Homebrew is busy; try again in a moment."))
        #expect(store.progressPanelTitle == "Replace finished with a warning")
    }

    /// A failed run with the same app still whole, and not the cask's version: both stay.
    @Test func failedRunWithTheAppWholeKeepsTheCopy() throws {
        let d = Dir(), fm = FileManager.default
        try FakeBundle.make(d.app, version: "1.0")
        let live = AppReplaceSafety.live(root: d.root)
        let copy = try live.backup(d.app.path)
        #expect(live.finish(d.app.path, copy, false, "2.0") == .kept(backup: copy))
        #expect(fm.fileExists(atPath: copy) && FakeBundle.version(d.app) == "1.0")
        // The run finished, so `.origin` is gone. The copy stays.
        #expect(!fm.fileExists(atPath: (copy as NSString).deletingLastPathComponent + "/.origin"))
    }

    /// brew's exit 0 isn't enough: the app must be whole and the cask's version.
    @Test func successNeedsAWholeAppOfTheCasksVersion() throws {
        let d = Dir(), fm = FileManager.default
        let live = AppReplaceSafety.live(root: d.root)
        try FakeBundle.make(d.app, version: "1.0")

        // Exit 0, but the app at the path is still 1.0: kept. `.origin` is gone.
        var copy = try live.backup(d.app.path)
        #expect(fm.fileExists(atPath: (copy as NSString).deletingLastPathComponent + "/.origin"))
        #expect(live.finish(d.app.path, copy, true, "2.0") == .kept(backup: copy))
        #expect(fm.fileExists(atPath: copy))
        #expect(!fm.fileExists(atPath: (copy as NSString).deletingLastPathComponent + "/.origin"))

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

    /// Same rule as the offer: a dotted cask version is the short version
    /// only (as text or by brew's ordering). A bare-integer cask may be the
    /// build number.
    @Test func successMatchFollowsTheOfferRule() {
        func info(_ short: String, _ build: String?) -> AppReplaceSafety.BundleInfo {
            .init(bundleID: "com.foo.Foo", shortVersion: short, bundleVersion: build)
        }
        // short 1.9, build 2.0.0, cask 2.0: the build is not consulted.
        #expect(!AppReplaceSafety.isVersion(info("1.9", "2.0.0"), "2.0"))
        // short 2.0 is the cask 2.0.0 by brew's ordering.
        #expect(AppReplaceSafety.isVersion(info("2.0", nil), "2.0.0"))
        // A bare integer may be the build number.
        #expect(AppReplaceSafety.isVersion(info("2.0", "200"), "200"))
        // Dotted, so build 200 is not consulted, and 2.0 is not 2.0.1.
        #expect(!AppReplaceSafety.isVersion(info("2.0", "200"), "2.0.1"))
    }

    /// A link, a missing executable, or an executable outside the bundle is
    /// not whole, so exit 0 does not delete the copy.
    @Test func aLinkOrAMissingExecutableIsNotAWholeApp() throws {
        let d = Dir(), fm = FileManager.default
        let live = AppReplaceSafety.live(root: d.root)
        try FakeBundle.make(d.app, version: "1.0")

        func notDiscarded(_ outcome: AppReplaceSafety.Outcome, _ why: String) {
            if case .discarded = outcome { Issue.record("\(why)") }
        }

        // The executable is a symlink. Exit 0 and the version would match.
        var copy = try live.backup(d.app.path)
        try FakeBundle.make(d.app, version: "2.0")
        let exe = d.app.appendingPathComponent("Contents/MacOS/Foo")
        try fm.removeItem(at: exe)
        try fm.createSymbolicLink(at: exe, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let linkedExe = live.finish(d.app.path, copy, true, "2.0")
        notDiscarded(linkedExe, "symlink executable deleted the copy")
        #expect(FakeBundle.version(d.app) == "1.0")

        // Info.plist is a symlink.
        copy = try live.backup(d.app.path)
        try FakeBundle.make(d.app, version: "2.0")
        let plist = d.app.appendingPathComponent("Contents/Info.plist")
        let aside = d.app.appendingPathComponent("Contents/Info-real.plist")
        try fm.moveItem(at: plist, to: aside)
        try fm.createSymbolicLink(at: plist, withDestinationURL: aside)
        notDiscarded(live.finish(d.app.path, copy, true, "2.0"), "symlink Info.plist deleted the copy")
        #expect(FakeBundle.version(d.app) == "1.0")

        // CFBundleExecutable is absent.
        copy = try live.backup(d.app.path)
        try FakeBundle.make(d.app, version: "2.0")
        let bare: [String: Any] = ["CFBundleIdentifier": "com.foo.Foo", "CFBundleShortVersionString": "2.0", "CFBundleVersion": "2.0"]
        try PropertyListSerialization.data(fromPropertyList: bare, format: .xml, options: 0).write(to: plist)
        notDiscarded(live.finish(d.app.path, copy, true, "2.0"), "missing CFBundleExecutable deleted the copy")
        #expect(FakeBundle.version(d.app) == "1.0")

        // The executable name leaves the bundle.
        copy = try live.backup(d.app.path)
        try FakeBundle.make(d.app, version: "2.0")
        let escaped: [String: Any] = ["CFBundleIdentifier": "com.foo.Foo", "CFBundleShortVersionString": "2.0",
                                      "CFBundleVersion": "2.0", "CFBundleExecutable": "../../../outside"]
        try PropertyListSerialization.data(fromPropertyList: escaped, format: .xml, options: 0).write(to: plist)
        try Data("x".utf8).write(to: d.url.appendingPathComponent("outside"))
        notDiscarded(live.finish(d.app.path, copy, true, "2.0"), "executable outside the bundle deleted the copy")
        #expect(FakeBundle.version(d.app) == "1.0")

        // A real bundle is still whole.
        try FakeBundle.make(d.app, version: "2.0")
        guard case .bundle = AppReplaceSafety.found(at: d.app.path) else {
            Issue.record("a real bundle was not whole")
            return
        }
    }

    // MARK: - leftovers at launch

    /// Launch never moves a copy, even when the app's path is empty and
    /// `.origin` names it. The text of `.origin` is not a path Tankard uses.
    @Test func launchNeverMovesALeftover() async throws {
        let d = Dir(), fm = FileManager.default
        try FakeBundle.make(d.app, version: "1.0")
        let live = AppReplaceSafety.live(root: d.root)
        let copy = try live.backup(d.app.path)
        let origin = ((copy as NSString).deletingLastPathComponent as NSString).appendingPathComponent(".origin")
        try Data("/tmp/ShouldNotAppear.app".utf8).write(to: URL(fileURLWithPath: origin))
        try fm.removeItem(at: d.app)

        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appReplaceSafety = live
        let store = AppStore(deps: deps)
        let listed = await store.noteReplaceLeftovers()
        #expect(listed == [copy])
        #expect(fm.fileExists(atPath: copy))
        #expect(!fm.fileExists(atPath: d.app.path))
        #expect(!fm.fileExists(atPath: "/tmp/ShouldNotAppear.app"))
        let notice = try #require(store.replaceLeftoverNotice)
        #expect(notice.paths == [copy])
        #expect(notice.message.contains("Foo"))
        #expect(notice.message.contains("safety copy"))
        #expect(!notice.message.contains("ShouldNotAppear"))
        #expect(!notice.message.contains("/tmp"))
        store.dismissReplaceLeftoverNotice()
        #expect(store.replaceLeftoverNotice == nil)
        #expect(fm.fileExists(atPath: copy))
    }

    /// A `<name>.app.partial` is what Homebrew left behind, moved aside. The
    /// notice names it that way, not as a safety copy. Show in Finder still
    /// gets its path. Nothing is moved or deleted.
    @Test func aPartialLeftoverIsNotCalledASafetyCopy() async throws {
        let d = Dir(), fm = FileManager.default
        let partialDir = d.root.appendingPathComponent("AAAA")
        let partial = partialDir.appendingPathComponent("Foo.app.partial")
        try fm.createDirectory(at: partial.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: partial.appendingPathComponent("Contents/Info.plist"))
        let numbered = partialDir.appendingPathComponent("Foo.app.partial-2")
        try fm.createDirectory(at: numbered, withIntermediateDirectories: true)
        #expect(AppReplaceSafety.describe(partial.path) == AppReplaceSafety.DescribedLeftover(
            path: partial.path, appName: "Foo",
            made: AppReplaceSafety.describe(partial.path).made, recordedPath: nil, partial: true))
        #expect(AppReplaceSafety.describe(numbered.path).partial && AppReplaceSafety.describe(numbered.path).appName == "Foo")
        #expect(!AppReplaceSafety.describe(d.root.appendingPathComponent("ZZZZ/Bar.app").path).partial)

        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appReplaceSafety = AppReplaceSafety.live(root: d.root)
        let store = AppStore(deps: deps)
        let listed = await store.noteReplaceLeftovers()
        #expect(listed == [numbered.path, partial.path].sorted())
        #expect(fm.fileExists(atPath: partial.path) && fm.fileExists(atPath: numbered.path))
        let notice = try #require(store.replaceLeftoverNotice)
        #expect(notice.paths == [numbered.path, partial.path].sorted())
        #expect(notice.message.contains("what Homebrew left of Foo"))
        #expect(!notice.message.contains("safety copy"))
        #expect(!notice.message.contains(".partial"))

        // A real copy beside it is still a safety copy. The partial is not.
        store.dismissReplaceLeftoverNotice()
        let copy = d.root.appendingPathComponent("BBBB").appendingPathComponent("Bar.app")
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        let listed2 = await store.noteReplaceLeftovers()
        #expect(Set(listed2) == Set([numbered.path, partial.path, copy.path]))
        let notice2 = try #require(store.replaceLeftoverNotice)
        #expect(notice2.message.contains("safety copy of Bar"))
        #expect(notice2.message.contains("what Homebrew left of Foo"))
        #expect(!notice2.message.contains("safety copy of Foo"))
        #expect(!notice2.message.contains(".partial"))
        #expect(notice2.paths.sorted() == [numbered.path, partial.path, copy.path].sorted())
        #expect(fm.fileExists(atPath: partial.path) && fm.fileExists(atPath: numbered.path) && fm.fileExists(atPath: copy.path))
    }

    @Test func launchListsLeftoversAndShowsOneNotice() async throws {
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        let safety = AppReplaceSafety(
            backup: { _ in calls.withLock { $0.append("backup") }; return "/tmp/x" },
            finish: { _, _, _, _ in calls.withLock { $0.append("finish") }; return .discarded },
            discard: { _ in calls.withLock { $0.append("discard") } },
            leftovers: { ["/c/A/Foo.app", "/c/B/Bar.app"] })
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appReplaceSafety = safety
        let store = AppStore(deps: deps)
        await store.start()
        #expect(await waitUntil { store.replaceLeftoverNotice != nil })
        let notice = try #require(store.replaceLeftoverNotice)
        #expect(notice.paths == ["/c/A/Foo.app", "/c/B/Bar.app"])
        #expect(notice.message.contains("Foo") || notice.message.contains("Bar"))
        #expect(!calls.withLock { $0.contains("finish") || $0.contains("discard") || $0.contains("backup") })
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
        #expect(await waitUntil { r.calls.withLock { $0.count } == 4 })
        #expect(r.calls.withLock { $0 } == ["read", "backup", "read", "finish true 4.0.2"])
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

    /// Updated itself while the copy was made: the second read differs, so
    /// no session starts and the copy is discarded.
    @Test func anAppThatChangesDuringTheCopyIsNotReplaced() async throws {
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        let reads = OSAllocatedUnfairLock<[AppReplaceSafety.BundleInfo?]>(initialState: [
            Self.audacity,
            .init(bundleID: "org.audacityteam.audacity4", shortVersion: "4.1.0", bundleVersion: "4.1.0"),
        ])
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appReplaceSafety = AppReplaceSafety(
            backup: { p in calls.withLock { $0.append("backup") }; return "/tmp/b/\((p as NSString).lastPathComponent)" },
            finish: { _, _, ok, v in calls.withLock { $0.append("finish \(ok) \(v)") }; return ok ? .discarded : .restored },
            discard: { _ in calls.withLock { $0.append("discard") } },
            readApp: { _ in
                calls.withLock { $0.append("read") }
                return reads.withLock { queued in queued.isEmpty ? nil : queued.removeFirst() }
            })
        let store = AppStore(deps: deps)
        store.settings.appManagementExplained = true
        await store.start()
        store.openAdopt()
        #expect(await waitUntil { store.adopt.phase == .ready })
        let p = try plan(store)
        #expect(await !store.startReplace(p))
        #expect(store.upgrade == nil)
        #expect(calls.withLock { $0 } == ["read", "backup", "read", "discard"])
        #expect(store.busyNotice?.contains("Audacity changed since the scan (it is now version 4.1.0)") == true)
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
        #expect(r.calls.withLock { $0 } == ["read", "backup", "read", "discard"])
        #expect(store.busyNotice?.contains("Audacity is open. Quit it first") == true)
    }

    /// Counts `brew install --cask --force` and whether the lock wait asked
    /// who holds the lock.
    final class LockRunner: StreamingCommandRunning, @unchecked Sendable {
        let inner: StreamingCommandRunning
        let installs = OSAllocatedUnfairLock(initialState: 0)
        let probes = OSAllocatedUnfairLock(initialState: 0)
        init(_ inner: StreamingCommandRunning) { self.inner = inner }
        func stream(_ executable: String, _ arguments: [String], environment: [String: String],
                    output: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
            if arguments.contains("--force") {
                installs.withLock { $0 += 1 }
                output(Data("Error: A `brew install --cask audacity` process has already locked /opt/homebrew/Caskroom/audacity.\n".utf8))
                return 1
            }
            return try await inner.stream(executable, arguments, environment: environment, output: output)
        }
    }

    /// brew's lock stops the run. It is not waited out and not run again.
    /// The copy is kept because the run failed.
    @Test func replaceDoesNotWaitOnBrewsLock() async throws {
        let r = Recorder(info: Self.audacity)
        var deps = Demo.dependencies(.arm64, pace: 0)
        let runner = LockRunner(deps.streamRunner)
        deps.streamRunner = runner
        deps.lockWait = BrewLockWait(interval: .milliseconds(20), limit: .milliseconds(300), maxAttempts: 5, holders: { _ in
            runner.probes.withLock { $0 += 1 }
            return ["99 brew install"]
        })
        deps.appReplaceSafety = AppReplaceSafety(
            backup: { [r] p in r.calls.withLock { $0.append("backup") }; return "/tmp/b/\((p as NSString).lastPathComponent)" },
            finish: { [r] _, backup, ok, v in
                r.calls.withLock { $0.append("finish \(ok) \(v)") }
                return ok ? .discarded : .kept(backup: backup)
            },
            discard: { [r] _ in r.calls.withLock { $0.append("discard") } },
            readApp: { [r] _ in r.calls.withLock { $0.append("read") }; return r.info.withLock { $0 } })
        let store = AppStore(deps: deps)
        store.settings.appManagementExplained = true
        await store.start()
        store.openAdopt()
        #expect(await waitUntil { store.adopt.phase == .ready })
        let p = try plan(store)
        #expect(await store.startReplace(p))
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        #expect(runner.installs.withLock { $0 } == 1)
        #expect(runner.probes.withLock { $0 } == 0)
        #expect(r.calls.withLock { $0.contains("finish false 4.0.2") })
        let lines = store.upgrade?.log.lines.joined(separator: "\n") ?? ""
        #expect(lines.contains("Homebrew is busy; try again in a moment."))
        #expect(lines.contains("wasn't replaced; it is as it was. Tankard kept a copy"))
        #expect(lines.contains("Another Homebrew command is running. brew allows one command at a time."))
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
