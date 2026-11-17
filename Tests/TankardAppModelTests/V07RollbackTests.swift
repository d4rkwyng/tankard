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
        // The uninstall knows the keg it brings back; nothing else needs one.
        #expect(uninstall.keg == RestoreStep.Keg(name: "xz", version: "5.8.2"))
        #expect(plan.steps.filter { $0.keg != nil }.count == 1)
        // brew install's periodic cleanup must not remove that keg first.
        #expect(plan.steps.filter { $0.kind == .reinstall }.allSatisfy { $0.environment == ["HOMEBREW_NO_INSTALL_CLEANUP": "1"] })
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
        // Only reinstalls, setting off: no variable. Setting on: always.
        let onlyRemoved = RestorePoint.capture([at("xz", "5.8.3"), at("wget", "1.25.0")], at: t0, reason: .upgrade)
        let reinstallOnly = RestorePlan.make(RestoreDiff.between(onlyRemoved, [at("xz", "5.8.3")]),
                                             installed: [at("xz", "5.8.3")], pinAfter: true)
        #expect(reinstallOnly.steps.map(\.environment) == [[:]])
        let kept = RestorePlan.make(RestoreDiff.between(onlyRemoved, [at("xz", "5.8.3")]),
                                    installed: [at("xz", "5.8.3")], pinAfter: true, keepPrevious: true)
        #expect(kept.steps.map(\.environment) == [["HOMEBREW_NO_INSTALL_CLEANUP": "1"]])
    }

    @Test func recheckDropsARollbackWhoseKegWasCleanedUp() {
        let xz = at("xz", "5.8.3", kegs: ["5.8.2", "5.8.3"])
        let git = at("git", "2.50.0_2", kegs: ["2.50.0_1", "2.50.0_2"])
        let point = RestorePoint.capture([at("xz", "5.8.2"), at("git", "2.50.0_1"), at("wget", "1.25.0")],
                                         at: t0, reason: .upgrade)
        var plan = RestorePlan.make(RestoreDiff.between(point, [xz, git]), installed: [xz, git], pinAfter: true)
        plan.source = RestorePlan.Source(point: point, pinAfter: true, keepPrevious: false)
        #expect(plan.steps.filter { $0.kind == .rollbackUninstall }.count == 2)

        // Nothing changed on disk: the same plan, no notice.
        let same = plan.rechecked(installed: [xz, git]) { _ in true }
        #expect(same.steps == plan.steps)
        #expect(same.notice == nil)

        // brew cleanup removed xz 5.8.2 after the plan was shown.
        let again = plan.rechecked(installed: [xz, git]) { $0 != RestoreStep.Keg(name: "xz", version: "5.8.2") }
        #expect(!again.steps.contains { $0.package == "formula:homebrew/core/xz" })
        #expect(again.steps.map(\.arguments) == [
            ["install", "--formula", "homebrew/core/wget"],
            ["uninstall", "--formula", "homebrew/core/git"],
            ["link", "--formula", "homebrew/core/git"],
            ["pin", "--formula", "homebrew/core/git"],
        ])
        #expect(again.manual.map(\.change.now.name) == ["xz"])
        #expect(again.manual.map(\.block) == [.cleanedUp])
        #expect(again.notice?.contains("xz 5.8.2") == true)

        // A plan without a source (or a stale one) is still checked keg by keg.
        var bare = plan
        bare.source = nil
        let checked = bare.rechecked(installed: []) { $0.name != "git" }
        #expect(!checked.steps.contains { $0.package == "formula:homebrew/core/git" })
        #expect(checked.steps.contains { $0.package == "formula:homebrew/core/xz" })
        #expect(checked.notice?.contains("git 2.50.0_1") == true)
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

    @Test func environmentForEveryUpgradeInstallAndReinstallWhenOn() {
        // Any of them can run brew's periodic cleanup, which removes every
        // formula's old kegs, so casks and installs get it too.
        let f = at("xz", "5.8.3"), c = at("iterm2", "3.6", kind: .cask)
        let on = ["HOMEBREW_NO_INSTALL_CLEANUP": "1"]
        for action in [SessionAction.upgrade, .install, .replaceBottle] {
            #expect(RollbackSettings.extraEnvironment(action, f, keep: true) == on, "\(action)")
            #expect(RollbackSettings.extraEnvironment(action, c, keep: true) == on, "\(action)")
            #expect(RollbackSettings.extraEnvironment(action, f, keep: false).isEmpty, "\(action)")
            #expect(RollbackSettings.extraEnvironment(action, c, keep: false).isEmpty, "\(action)")
        }
        for action in [SessionAction.uninstall, .cleanup, .autoremove, .tap, .untap, .restore] {
            #expect(RollbackSettings.extraEnvironment(action, f, keep: true).isEmpty, "\(action)")
        }
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
        // A cask install in the same session gets it too (brew install can
        // run the periodic cleanup that removes the formula's old keg).
        store.closeUpgrade()
        store.startSession(.install, packages: [Package.placeholder(kind: .cask, name: "iterm2")])
        let install = try #require(store.upgrade?.items.first?.command)
        #expect(install.arguments.first == "install")
        #expect(install.environment["HOMEBREW_NO_INSTALL_CLEANUP"] == "1")
        #expect(install.display.hasPrefix("HOMEBREW_NO_INSTALL_CLEANUP=1 brew install --cask"))
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

    /// A store over the demo's Intel fixture whose Cellar is `kegs`, with
    /// two leaf formulae upgraded and their old kegs kept, and a restore
    /// point from before.
    func rollbackStore(_ kegs: KegSet, runner: FakeStreamRunner) async throws -> (AppStore, RestorePoint, [Package]) {
        let log = CallLog()
        let client = BrewClient(installation: intelInstall, platform: intelPlatform, runner: FakeInfoRunner(log: log, info: demoIntelInfo()),
                                sources: EnvironmentSources(process: ["HOME": "/Users/test", "USER": "test",
                                                                      "HOMEBREW_CORE_GIT_REMOTE": Intelbrew.coreRemote]),
                                fileExists: { kegs.contains($0) })
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil))
        await store.start()
        var report = try #require(store.report)
        let pkgs = report.packages
        let leaves = Array(pkgs.filter { p in
            p.kind == .formula && !p.pinned && p.kegOnly != true && !p.installedVersion.hasPrefix("HEAD")
                && Dependents.of(p, among: pkgs).isEmpty
        }.prefix(2))
        try #require(leaves.count == 2)
        for l in leaves {
            let i = try #require(report.packages.firstIndex { $0.id == l.id })
            report.packages[i].installedVersions = [Demo.olderVersion(l.installedVersion), l.installedVersion]
            kegs.insert("/usr/local/Cellar/\(l.name)/\(Demo.olderVersion(l.installedVersion))")
            kegs.insert("/usr/local/Cellar/\(l.name)/\(l.installedVersion)")
        }
        store.report = report
        var point = RestorePoint.capture(pkgs, at: t0, reason: .upgrade)
        for l in leaves {
            let i = try #require(point.packages.firstIndex { $0.id == l.id })
            point.packages[i].version = Demo.olderVersion(l.installedVersion)
        }
        return (store, point, leaves)
    }

    @Test func confirmRechecksTheCellarAndNeverUninstallsTheLastKeg() async throws {
        let kegs = KegSet()
        let log = CallLog()
        let runner = FakeStreamRunner(log: log, behaviour: { _, _ in 0 })
        let (store, point, leaves) = try await rollbackStore(kegs, runner: runner)
        let (gone, kept) = (leaves[0], leaves[1])
        store.requestRestore(point, pinAfter: false)
        let shown = try #require(store.restorePoints.pendingPlan)
        #expect(shown.steps.filter { $0.kind == .rollbackUninstall }.count == 2)

        // `brew cleanup` in Terminal, after the plan was shown.
        kegs.remove("/usr/local/Cellar/\(gone.name)/\(Demo.olderVersion(gone.installedVersion))")
        store.confirmRestore()
        // Nothing ran; the confirmation now shows the smaller plan and why.
        #expect(store.upgrade == nil)
        let again = try #require(store.restorePoints.pendingPlan)
        #expect(again.notice?.contains(gone.name) == true)
        #expect(!again.steps.contains { $0.package == gone.id })
        #expect(again.steps.filter { $0.package == kept.id }.map(\.kind) == [.rollbackUninstall, .rollbackLink])
        #expect(again.manual.contains { $0.change.now.id == gone.id && $0.block == .cleanedUp })

        // Confirming that one runs only the other package's steps.
        store.confirmRestore()
        #expect(store.restorePoints.pendingPlan == nil)
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        let ran = log.calls.filter { ["uninstall", "link"].contains($0.first) }
        #expect(ran == [["uninstall", "--formula", kept.qualifiedName], ["link", "--formula", kept.qualifiedName]])
        #expect(!log.calls.contains { $0.first == "uninstall" && $0.last == gone.qualifiedName })
    }

    @Test func kegGoneRightBeforeTheUninstallSkipsThatPackageOnly() async throws {
        let kegs = KegSet()
        let log = CallLog()
        let target = LockedBox<String>()
        // The first package's link: brew's periodic cleanup (as if run by
        // something else) removes the second package's old keg.
        let runner = FakeStreamRunner(log: log, behaviour: { args, _ in
            if args.first == "link", let path = target.value { kegs.remove(path) }
            return 0
        })
        let (store, point, leaves) = try await rollbackStore(kegs, runner: runner)
        store.requestRestore(point, pinAfter: true)
        let plan = try #require(store.restorePoints.pendingPlan)
        let order = plan.steps.filter { $0.kind == .rollbackUninstall }.map(\.package)
        let first = try #require(leaves.first { $0.id == order.first })
        let second = try #require(leaves.first { $0.id == order.last })
        target.value = "/usr/local/Cellar/\(second.name)/\(Demo.olderVersion(second.installedVersion))"

        store.confirmRestore()
        #expect(store.upgrade?.action == .restore)
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        let ran = log.calls.filter { ["uninstall", "link", "pin"].contains($0.first) }
        #expect(ran == [["uninstall", "--formula", first.qualifiedName], ["link", "--formula", first.qualifiedName],
                        ["pin", "--formula", first.qualifiedName]])
        let session = try #require(store.upgrade)
        let states = session.items.map(\.state)
        #expect(states == [.done, .done, .done, .failed(-1), .cancelled, .cancelled])
        let text = session.log.lines.joined(separator: "\n")
        #expect(text.contains("\(second.name) \(Demo.olderVersion(second.installedVersion)) is no longer in the Cellar"))
        #expect(text.contains("Skipped the uninstall"))
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

/// The fake Cellar: paths that exist.
final class KegSet: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []
    func insert(_ p: String) { _ = lock.withLock { paths.insert(p) } }
    func remove(_ p: String) { _ = lock.withLock { paths.remove(p) } }
    func contains(_ p: String) -> Bool { lock.withLock { paths.contains(p) } }
}

final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
