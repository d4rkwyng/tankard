import Foundation
import os
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.8.10: Adopt Apps' "Replace with Homebrew's Version": offered only for
// a sure match whose cask is newer, the plan sheet's facts, an open app
// blocks it (Tankard asks, never quits it), `brew install --cask --force`
// through the queue, and the safety copy put back when brew fails.

/// Records what the run did with the safety copy.
final class FakeReplaceSafety: Sendable {
    let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
    let failBackup: Bool
    let outcomeOnFailure: AppReplaceSafety.Outcome
    init(failBackup: Bool = false, outcomeOnFailure: AppReplaceSafety.Outcome = .restored) {
        self.failBackup = failBackup
        self.outcomeOnFailure = outcomeOnFailure
    }
    var safety: AppReplaceSafety {
        AppReplaceSafety(
            backup: { [self] path in
                calls.withLock { $0.append("backup \(path)") }
                if failBackup { throw CocoaError(.fileReadNoPermission) }
                return "/tmp/backup/\((path as NSString).lastPathComponent)"
            },
            finish: { [self] path, _, ok, _ in
                calls.withLock { $0.append("finish \(path) \(ok)") }
                return ok ? .discarded : outcomeOnFailure
            })
    }
}

@MainActor
struct V0810ReplaceAppTests {
    func demo(_ safety: FakeReplaceSafety? = nil) async throws -> AppStore {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appReplaceSafety = safety?.safety
        let store = AppStore(deps: deps)
        store.settings.appManagementExplained = true
        await store.start()
        store.openAdopt()
        #expect(await waitUntil { store.adopt.phase == .ready })
        return store
    }

    /// 0.8.10: the demo's Audacity (its cask installs one app only; GIMP's
    /// also installs a command wrapper, so it isn't offered).
    func audacity(_ store: AppStore) throws -> AdoptRow {
        try #require(store.adopt.rows(.needsUpdate).first { $0.app.displayName == "Audacity" })
    }

    static func app(_ v: String) -> InstalledApp {
        InstalledApp(path: "/Applications/Foo.app", root: "/Applications", relativePath: "Foo.app", bundleID: "com.foo.Foo",
                     shortVersion: v, bundleVersion: v)
    }

    func adoptStore(cask: String, app: String, ids: Set<String> = ["com.foo.foo"]) -> AdoptStore {
        let c = AdoptCask(token: "foo", version: cask,
                          apps: [.init(source: "Foo.app", target: "/Applications/Foo.app")], bundleIDs: ids)
        let a = AdoptStore()
        a.apply(AdoptInput(index: AdoptIndex(casks: [c]), apps: [Self.app(app)], source: "test"))
        return a
    }

    @Test func offeredOnlyWhenTheCaskIsNewer() throws {
        let newer = adoptStore(cask: "2.1", app: "2.0")
        let row = try #require(newer.scan.rows.first)
        #expect(newer.group(row) == .needsUpdate && newer.offersReplace(row))
        let plan = try #require(newer.replacePlan(row))
        #expect(plan.installedVersion == "2.0" && plan.caskVersion == "2.1" && plan.token == "foo")
        #expect(plan.arguments == ["install", "--cask", "--force", "homebrew/cask/foo"])

        // A downgrade: brew can't adopt it either, but it isn't offered.
        let older = adoptStore(cask: "1.9", app: "2.0")
        let o = try #require(older.scan.rows.first)
        #expect(older.group(o) == .needsUpdate && !older.offersReplace(o) && older.replacePlan(o) == nil)

        // The same version by brew's ordering.
        let same = adoptStore(cask: "2.0.0", app: "2.0")
        let s = try #require(same.scan.rows.first)
        #expect(same.group(s) == .needsUpdate && !same.offersReplace(s))

        // Newer, but only the name matches: it could be a different app.
        let nameOnly = adoptStore(cask: "2.1", app: "2.0", ids: [])
        let n = try #require(nameOnly.scan.rows.first)
        #expect(nameOnly.group(n) == .needsUpdate && nameOnly.confidence(n) != .high && !nameOnly.offersReplace(n))

        // Ready to adopt: nothing to replace.
        let ready = adoptStore(cask: "2.0", app: "2.0")
        let r = try #require(ready.scan.rows.first)
        #expect(ready.group(r) == .ready && !ready.offersReplace(r))
    }

    @Test func planSheetSaysWhatChanges() async throws {
        let store = try await demo()
        let row = try audacity(store)
        store.requestReplace(row)
        let plan = try #require(store.adopt.pendingReplace)
        #expect(plan.appName == "Audacity" && plan.installedVersion == "4.0.1" && plan.caskVersion == "4.0.2")
        #expect(plan.planLines.contains("Your settings and data in ~/Library are not touched."))
        #expect(plan.planLines.contains { $0.hasPrefix("From now on Homebrew manages this app") })
        #expect(plan.planLines.contains("If brew fails, the app is left as it was."))
        #expect(!store.adopt.replaceAppOpen)
        store.cancelReplace()
        #expect(store.adopt.pendingReplace == nil && store.upgrade == nil)
    }

    @Test func anOpenAppMustBeQuitFirst() async throws {
        let store = try await demo()
        let row = try audacity(store)
        let open = FixedConditions(ac: nil, idle: nil, apps: [RunningApp(path: "/Applications/Audacity 4.app", bundleID: nil)])
        store.autoUpdate.conditions = open
        store.requestReplace(row)
        #expect(store.adopt.replaceAppOpen)
        #expect(store.adopt.pendingReplace?.runningNote.contains("Audacity is open. Quit it first") == true)
        // Replace stays on the sheet; nothing runs.
        #expect(!store.confirmReplace())
        #expect(store.adopt.pendingReplace != nil && store.upgrade == nil)
        // Found by its bundle id too (another copy, another path).
        open.apps = [RunningApp(path: "/Users/x/Applications/Audacity 4.app", bundleID: "ORG.audacityteam.AUDACITY4")]
        store.refreshReplaceRunning()
        #expect(store.adopt.replaceAppOpen)
        // Quit: Check Again clears it.
        open.apps = []
        store.refreshReplaceRunning()
        #expect(!store.adopt.replaceAppOpen)
    }

    @Test func replaceRunsForceInstallThroughTheQueue() async throws {
        let safety = FakeReplaceSafety()
        let store = try await demo(safety)
        store.requestReplace(try audacity(store))
        #expect(store.confirmReplace())
        #expect(store.adopt.pendingReplace == nil)
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        let s = try #require(store.upgrade)
        #expect(s.action == .replaceApp)
        #expect(s.items.count == 1 && s.items[0].state == .done)
        #expect(Array(s.items[0].command.arguments.prefix(3)) == ["install", "--cask", "--force"])
        #expect(s.items[0].command.arguments.last?.hasSuffix("audacity") == true)
        #expect(await waitUntil { safety.calls.withLock { $0.count } == 2 })
        #expect(safety.calls.withLock { $0 } == ["backup /Applications/Audacity 4.app", "finish /Applications/Audacity 4.app true"])
    }

    @Test func failedBrewPutsTheAppBack() async throws {
        let safety = FakeReplaceSafety()
        let store = try await demo(safety)
        // A cask the demo's brew doesn't know: brew fails.
        let plan = ReplaceAppPlan(token: "no-such-cask", qualifiedName: "homebrew/cask/no-such-cask", appName: "Nothing",
                                  appPath: "/Applications/Nothing.app", bundleID: nil, installedVersion: "1.0", caskVersion: "2.0")
        store.closeToolSheet()
        #expect(await store.startReplace(plan))
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        let s = try #require(store.upgrade)
        #expect(s.items[0].state != .done)
        #expect(await waitUntil { s.log.lines.contains { $0.contains("Tankard put the old version back at /Applications/Nothing.app") } })
        #expect(safety.calls.withLock { $0 }.last == "finish /Applications/Nothing.app false")
    }

    @Test func noSafetyCopyNoReplace() async throws {
        let safety = FakeReplaceSafety(failBackup: true)
        let store = try await demo(safety)
        store.requestReplace(try audacity(store))
        let plan = try #require(store.adopt.pendingReplace)
        store.cancelReplace()
        store.closeToolSheet()
        #expect(await !store.startReplace(plan))
        #expect(store.upgrade == nil)
        #expect(store.busyNotice?.contains("couldn't make a safety copy of Audacity") == true)
    }

    /// The real copy, on a folder standing in for an app.
    @Test func liveSafetyCopyRestoresAndCleansUp() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("tankard-replace-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let apps = tmp.appendingPathComponent("Applications"), root = tmp.appendingPathComponent("backups")
        let app = apps.appendingPathComponent("Foo.app")
        try FakeBundle.make(app, version: "1.0")
        let live = AppReplaceSafety.live(root: root)

        // brew failed after removing the app: the copy goes back.
        var copy = try live.backup(app.path)
        try fm.removeItem(at: app)
        #expect(live.finish(app.path, copy, false, "2.0") == .restored)
        #expect(FakeBundle.version(app) == "1.0")
        #expect((try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty ?? true)

        // brew failed before touching it: the app stays, the copy too
        // (0.8.10: a failed run never deletes the copy unless it is back).
        copy = try live.backup(app.path)
        #expect(live.finish(app.path, copy, false, "2.0") == .kept(backup: copy))
        #expect(FakeBundle.version(app) == "1.0" && FakeBundle.version(URL(fileURLWithPath: copy)) == "1.0")
        try fm.removeItem(atPath: (copy as NSString).deletingLastPathComponent)

        // brew succeeded: the copy is deleted, the new app stays.
        copy = try live.backup(app.path)
        try FakeBundle.make(app, version: "2.0")
        #expect(live.finish(app.path, copy, true, "2.0") == .discarded)
        #expect(FakeBundle.version(app) == "2.0")
        #expect((try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty ?? true)

        // No app to copy: an error, nothing left behind.
        #expect(throws: (any Error).self) { try live.backup(apps.appendingPathComponent("Missing.app").path) }
        #expect((try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty ?? true)
    }
}

/// A minimal app bundle on disk: Info.plist and its executable.
enum FakeBundle {
    static func make(_ app: URL, id: String = "com.foo.Foo", version: String, build: String? = nil,
                     executable: Bool = true, infoPlist: Bool = true) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: app)
        let macos = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        if infoPlist {
            let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version,
                                       "CFBundleVersion": build ?? version, "CFBundleExecutable": "Foo"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
        }
        if executable { try Data("#!/bin/sh\n".utf8).write(to: macos.appendingPathComponent("Foo")) }
    }

    static func version(_ app: URL) -> String? {
        guard let d = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
        return p["CFBundleShortVersionString"] as? String
    }
}
