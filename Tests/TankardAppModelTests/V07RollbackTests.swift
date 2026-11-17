import Foundation
import Observation
import Testing
import TankardCore
@testable import TankardAppModel

/// A formula/cask at `version`, with every kept keg in `kegs`.
private func at(_ name: String, _ version: String, kegs: [String]? = nil, kind: PackageKind = .formula,
                pinned: Bool = false, kegOnly: Bool? = nil, deps: [String] = []) -> Package {
    var p = pkg(name, kind: kind, outdated: false, pinned: pinned, deps: deps)
    p.installedVersion = version
    p.installedVersions = kegs ?? [version]
    p.kegOnly = kegOnly
    return p
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
struct RestorePointStorageTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tankard-rp-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func savesLoadsAndCapsAtTwenty() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RestorePointStore(directory: dir, settings: RollbackSettings(defaults: freshDefaults()))
        for i in 0..<(RestorePointStore.maxPoints + 5) {
            store.save(RestorePoint.capture([at("xz", "5.8.\(i)")], at: t0.addingTimeInterval(Double(i)), reason: .upgrade))
        }
        #expect(store.points.count == RestorePointStore.maxPoints)
        #expect(store.points.first?.createdAt == t0.addingTimeInterval(Double(RestorePointStore.maxPoints + 4)))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }
        #expect(files.count == RestorePointStore.maxPoints)
        let again = RestorePointStore(directory: dir, settings: RollbackSettings(defaults: freshDefaults()))
        #expect(again.points == store.points)
        // Oldest dropped: the first five versions are gone.
        #expect(!again.points.contains { $0.packages.first?.version == "5.8.0" })
        again.delete(again.points[0].id)
        #expect(RestorePointStore(directory: dir, settings: RollbackSettings(defaults: freshDefaults())).points.count == RestorePointStore.maxPoints - 1)
    }

    @Test func captureRecordsVersionsTapsPinsAndBrewfile() {
        var tapped = at("tool", "2.0")
        tapped.id = "formula:user/tools/tool"
        tapped.tap = "user/tools"
        let p = RestorePoint.capture([at("xz", "5.8.3", pinned: true), at("iterm2", "3.6", kind: .cask), tapped,
                                      Package.command("brew cleanup")], at: t0, reason: .autoUpdate, note: "xz")
        #expect(p.packages.count == 3)
        #expect(p.packages.first { $0.name == "xz" }?.version == "5.8.3")
        #expect(p.pins == ["xz"])
        #expect(p.taps == ["homebrew/cask", "homebrew/core", "user/tools"])
        #expect(p.brewfile.contains("tap \"user/tools\""))
        #expect(!p.brewfile.contains("tap \"homebrew/core\""))
        #expect(p.brewfile.contains("brew \"user/tools/tool\""))
        #expect(p.brewfile.contains("cask \"homebrew/cask/iterm2\""))
    }
}

@MainActor
struct RestoreDiffTests {
    @Test func diffsUpgradedAddedRemovedTapsPins() {
        var gone = at("wget", "1.25.0")
        gone.tap = "user/old"
        gone.id = "formula:user/old/wget"
        let point = RestorePoint.capture([at("xz", "5.8.2"), at("git", "2.50.0_1"), at("jq", "1.8"), gone,
                                          at("node", "24.1")], at: t0, reason: .upgrade)
        var nodeNow = at("node", "24.0")
        nodeNow.pinned = true
        let now = [at("xz", "5.8.3"), at("git", "2.50.0_2"), at("jq", "1.8"), at("ripgrep", "15.0"), nodeNow]
        let d = RestoreDiff.between(point, now)
        #expect(d.upgraded.map(\.now.name).sorted() == ["git", "xz"])
        #expect(d.upgraded.first { $0.now.name == "git" }?.then.version == "2.50.0_1")
        #expect(d.downgraded.map(\.now.name) == ["node"])
        #expect(d.added.map(\.name) == ["ripgrep"])
        #expect(d.removed.map(\.name) == ["wget"])
        #expect(d.tapsRemoved == ["user/old"])
        #expect(d.tapsAdded.isEmpty)
        #expect(d.pinsChanged == ["node"])
        #expect(!d.isEmpty)
        #expect(RestoreDiff.between(RestorePoint.capture(now, at: t0, reason: .manual), now).isEmpty)
    }
}

@MainActor
struct RollbackEligibilityTests {
    func change(_ then: String, _ now: Package) -> RestoreDiff.Change {
        var t = RestorePointPackage(now)
        t.version = then
        return RestoreDiff.Change(then: t, now: now)
    }

    @Test func automaticOnlyWhenTheOldKegIsWhatLinkWouldPick() {
        let xz = at("xz", "5.8.3", kegs: ["5.8.2", "5.8.3"])
        #expect(RollbackPolicy.eligibility(change("5.8.2", xz), installed: [xz]) == .automatic)
    }

    @Test func blockedWithReasons() {
        func check(_ then: String, _ p: Package, among extra: [Package] = [], _ block: RollbackBlock) {
            #expect(RollbackPolicy.eligibility(change(then, p), installed: [p] + extra) == .manual(block), "\(p.name)")
        }
        check("5.8.2", at("xz", "5.8.3"), .cleanedUp)
        check("3.5", at("iterm2", "3.6", kegs: ["3.5", "3.6"], kind: .cask), .cask)
        check("3.4", at("openssl@3", "3.5", kegs: ["3.4", "3.5"], kegOnly: true), .kegOnly)
        check("1.7", at("jq", "1.8", kegs: ["1.7", "1.8"], pinned: true), .pinned)
        check("5.8.2", at("xz", "5.8.3", kegs: ["5.8.2", "5.8.3"]), among: [at("git", "2.5", deps: ["xz"])], .hasDependents)
        // Three kegs: link would pick 5.8.2, not the recorded 5.8.1.
        check("5.8.1", at("xz", "5.8.3", kegs: ["5.8.1", "5.8.2", "5.8.3"]), .otherKegWouldLink)
        check("HEAD-abc", at("tool", "HEAD-def", kegs: ["HEAD-abc", "HEAD-def"]), .headVersion)
    }

    @Test func revisionsCompare() {
        // 2.50.0_1 kept, 2.50.0_2 in use: link picks _1 once _2 is gone.
        let git = at("git", "2.50.0_2", kegs: ["2.50.0_1", "2.50.0_2"])
        #expect(RollbackPolicy.eligibility(change("2.50.0_1", git), installed: [git]) == .automatic)
        #expect(RollbackPolicy.isOlder("2.50.0_1", than: "2.50.0_2"))
        #expect(RollbackPolicy.isOlder("5.8.10", than: "5.9"))
    }

    @Test func manualCommandsAreShownNotRun() {
        let xz = at("xz", "5.8.3")
        #expect(RollbackPolicy.manualCommands(change("5.8.2_1", xz), block: .cleanedUp)
                == ["brew tap --force homebrew/core", "brew version-install xz 5.8.2"])
        #expect(RollbackPolicy.manualCommands(change("3.5", at("iterm2", "3.6", kind: .cask)), block: .cask).isEmpty)
        for b in RollbackBlock.allCases {
            #expect(!b.title.isEmpty && !b.explanation.isEmpty)
        }
    }
}

@MainActor
struct RestorePlanTests {
    @Test func planArgv() {
        let xz = at("xz", "5.8.3", kegs: ["5.8.2", "5.8.3"])
        let jq = at("jq", "1.8")            // cleaned up
        let point = RestorePoint.capture([at("xz", "5.8.2"), at("jq", "1.7"), at("wget", "1.25.0"),
                                          at("iterm2", "3.5", kind: .cask)], at: t0, reason: .upgrade)
        let now = [xz, jq]
        let plan = RestorePlan.make(RestoreDiff.between(point, now), installed: now, pinAfter: true)
        #expect(plan.steps.map(\.arguments) == [
            ["install", "--cask", "homebrew/cask/iterm2"],
            ["install", "--formula", "homebrew/core/wget"],
            ["uninstall", "--formula", "homebrew/core/xz"],
            ["link", "--formula", "homebrew/core/xz"],
            ["pin", "--formula", "homebrew/core/xz"],
        ])
        let uninstall = plan.steps[2]
        #expect(plan.steps.map(\.kind) == [.reinstall, .reinstall, .rollbackUninstall, .rollbackLink, .pin])
        #expect(uninstall.environment == ["HOMEBREW_NO_AUTOREMOVE": "1"])
        #expect(uninstall.display == "HOMEBREW_NO_AUTOREMOVE=1 brew uninstall --formula homebrew/core/xz")
        #expect(plan.manual.map(\.change.now.name) == ["jq"])
        #expect(plan.manual.map(\.block) == [.cleanedUp])
        // Never --force, never --ignore-dependencies, never the dependents-check bypass.
        for s in plan.steps {
            #expect(!s.arguments.contains("--force") && !s.arguments.contains("--ignore-dependencies") && !s.arguments.contains("--overwrite"))
            #expect(s.environment["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] == nil)
        }
        let noPin = RestorePlan.make(RestoreDiff.between(point, now), installed: now, pinAfter: false)
        #expect(!noPin.steps.contains { $0.kind == .pin })
        // Added packages are never uninstalled.
        let added = RestorePlan.make(RestoreDiff.between(RestorePoint.capture([], at: t0, reason: .manual), now),
                                     installed: now, pinAfter: true)
        #expect(added.steps.isEmpty)
    }

    @Test func queuedCommandCarriesNoAutoUpdate() {
        let step = RestoreStep(kind: .rollbackUninstall, package: "formula:homebrew/core/xz",
                               arguments: ["uninstall", "--formula", "homebrew/core/xz"],
                               environment: ["HOMEBREW_NO_AUTOREMOVE": "1"])
        let cmd = AppStore.restoreCommand(step, brew: "/usr/local/bin/brew", base: ["HOME": "/Users/test"])
        #expect(cmd.executable == "/usr/local/bin/brew")
        #expect(cmd.arguments == step.arguments)
        #expect(cmd.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(cmd.environment["HOMEBREW_NO_AUTOREMOVE"] == "1")
        #expect(cmd.environment["HOME"] == "/Users/test")
    }
}

@MainActor
struct RollbackSettingsTests {
    @Test func equalWritesDropped() {
        let d = freshDefaults()
        let s = RollbackSettings(defaults: d)
        let notified = Flag()
        withObservationTracking { _ = s.keepPreviousVersion } onChange: { notified.set() }
        s.keepPreviousVersion = false
        #expect(!notified.value)
        #expect(d.object(forKey: "keepPreviousVersionAfterUpgrade") == nil)
        s.keepPreviousVersion = true
        #expect(notified.value)
        #expect(RollbackSettings(defaults: d).keepPreviousVersion)
    }

    @Test func environmentOnlyForFormulaUpgradesWhenOn() {
        let f = at("xz", "5.8.3"), c = at("iterm2", "3.6", kind: .cask)
        #expect(RollbackSettings.extraEnvironment(.upgrade, f, keep: true) == ["HOMEBREW_NO_INSTALL_CLEANUP": "1"])
        #expect(RollbackSettings.extraEnvironment(.upgrade, f, keep: false).isEmpty)
        #expect(RollbackSettings.extraEnvironment(.upgrade, c, keep: true).isEmpty)
        #expect(RollbackSettings.extraEnvironment(.install, f, keep: true).isEmpty)
        #expect(RollbackSettings.extraEnvironment(.cleanup, f, keep: true).isEmpty)
    }
}

@MainActor
struct RestoreStoreTests {
    @Test func upgradeSavesAPointAndKeepAddsTheVariable() async throws {
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: log, behaviour: { _, _ in 0 })
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil))
        await store.start()
        store.restorePoints.settings.keepPreviousVersion = true
        let xz = try #require(store.packages.first { $0.name == "xz" && $0.upgradeAvailable })
        #expect(store.restorePoints.points.isEmpty)
        store.startUpgrade([xz])
        #expect(store.restorePoints.points.count == 1)
        #expect(store.restorePoints.points[0].reason == .upgrade)
        #expect(store.restorePoints.points[0].packages.first { $0.name == "xz" }?.version == xz.installedVersion)
        let cmd = try #require(store.upgrade?.items.first?.command)
        #expect(cmd.environment["HOMEBREW_NO_INSTALL_CLEANUP"] == "1")
        #expect(cmd.display.hasPrefix("HOMEBREW_NO_INSTALL_CLEANUP=1 brew upgrade"))
        #expect(await waitUntil { store.upgrade?.isFinished == true })
    }

    @Test func restoreRunsThroughTheQueueChainsAndRecordsHistory() async throws {
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        // The first uninstall fails (as brew does when something needs it).
        let runner = FakeStreamRunner(log: log, behaviour: { args, out in
            if args.first == "uninstall", args.last == "homebrew/core/aaa" {
                out(Data("Error: Refusing to uninstall\n".utf8))
                return 1
            }
            return 0
        })
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil))
        await store.start()
        func step(_ k: RestoreStep.Kind, _ pkg: String, _ args: [String]) -> RestoreStep {
            RestoreStep(kind: k, package: pkg, arguments: args, environment: k == .rollbackUninstall ? ["HOMEBREW_NO_AUTOREMOVE": "1"] : [:])
        }
        let plan = RestorePlan(steps: [
            step(.rollbackUninstall, "a", ["uninstall", "--formula", "homebrew/core/aaa"]),
            step(.rollbackLink, "a", ["link", "--formula", "homebrew/core/aaa"]),
            step(.rollbackUninstall, "b", ["uninstall", "--formula", "homebrew/core/bbb"]),
            step(.rollbackLink, "b", ["link", "--formula", "homebrew/core/bbb"]),
        ])
        store.restorePoints.pendingPlan = plan
        store.confirmRestore()
        #expect(store.upgrade?.action == .restore)
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        let ran = log.calls.filter { ["uninstall", "link"].contains($0.first) }
        // aaa's link is skipped after its uninstall failed; bbb still runs.
        #expect(ran == [["uninstall", "--formula", "homebrew/core/aaa"],
                        ["uninstall", "--formula", "homebrew/core/bbb"],
                        ["link", "--formula", "homebrew/core/bbb"]])
        #expect(store.upgrade?.items[1].state == .cancelled)
        #expect(await waitUntil { store.history.entries.filter { ["uninstall", "link"].contains($0.arguments.first) }.count == 3 })
        #expect(store.history.entries.contains { $0.command == "HOMEBREW_NO_AUTOREMOVE=1 brew uninstall --formula homebrew/core/bbb" })
    }

    @Test func demoSeedsOneOfEachKind() async {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await store.start()
        Demo.seedRestorePoints(store, now: t0)
        let p = store.restorePoints.points[0]
        let d = store.restoreDiff(p)
        let kinds = d.upgraded.map { RollbackPolicy.eligibility($0, installed: store.packages) }
        #expect(kinds.contains(.automatic))
        #expect(kinds.contains(.manual(.cleanedUp)))
        // (The Intelbrew demo has no casks.)
        #expect(d.removed.map(\.name) == ["wget"])
        #expect(d.added.count == 1)
    }
}
