import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.1: App Management for every action that writes into /Applications
// (install, adopt, reinstall, upgrade, uninstall, auto-update), the
// relaunch after the grant, and the write probe.

@MainActor
struct V081AppManagementTests {
    // brew 7's own messages (Homebrew/brew cask/staged.rb, install_steps.rb,
    // cask/quarantine.rb) and macOS's, as printed.
    static let stagedError = [
        "==> Upgrading 1 outdated package:",
        "Error: Cannot change the ownership of '/Applications/Firefox.app' because your terminal does not have App Management permissions.",
        "macOS prevents modifying apps without these permissions, even when using `sudo`.",
        "To fix this, approve the permissions prompt (if one was just shown) or go to",
        "System Settings → Privacy & Security → App Management and add or enable your terminal.",
        "Then run this command again.",
    ]
    static let writeTest = ["touch: /Applications/Firefox.app/.homebrew-write-test: Operation not permitted"]
    static let rmBlocked = ["Error: Operation not permitted @ apply2files - /Users/me/Applications/Foo.app/Contents/Info.plist"]

    @Test func brewsMessagesAreClassifiedAsAppManagement() {
        #expect(BrewFailure.classify(Self.stagedError) == .appManagement)
        #expect(BrewFailure.classify(Self.writeTest) == .appManagement)
        #expect(BrewFailure.classify(Self.rmBlocked) == .appManagement)
        #expect(BrewFailure.classify(["“Tankard” was prevented from modifying apps on your Mac."]) == .appManagement)
        // Not an app: still Homebrew's own folders.
        #expect(BrewFailure.classify(["Error: Operation not permitted @ dir_s_mkdir - /usr/local/Cellar/x"]) == .permissions)
        #expect(BrewFailure.classify(["Error: Permission denied @ rb_sysopen - /opt/homebrew/var/x"]) == .permissions)
        #expect(!BrewFailureKind.appManagement.explanation.isEmpty)
        #expect(AppManagement.isPermissionBlock(Self.stagedError))
    }

    @Test func everyCaskWriteCounts() {
        let cask = CatalogEntry(kind: .cask, name: "firefox", fullName: "firefox", tap: "homebrew/cask", desc: nil, bottle: .cask).asPackage()
        let formula = CatalogEntry(kind: .formula, name: "xz", fullName: "xz", tap: "homebrew/core", desc: nil, bottle: .intelbrew).asPackage()
        for a in [SessionAction.install, .adopt, .upgrade, .uninstall] {
            #expect(AppManagement.isCaskChange(a, cask))
            #expect(!AppManagement.isCaskChange(a, formula))
        }
        for a in [SessionAction.replaceBottle, .cleanup, .autoremove, .tap, .untap, .restore] {
            #expect(!AppManagement.isCaskChange(a, cask))
        }
        #expect(AppManagement.isCaskCommand(["install", "--cask", "homebrew/cask/firefox"]))
        #expect(AppManagement.isCaskCommand(["install", "--cask", "--adopt", "homebrew/cask/firefox"]))
        #expect(AppManagement.isCaskCommand(["reinstall", "--cask", "firefox"]))
        #expect(!AppManagement.isCaskCommand(["install", "--formula", "homebrew/core/xz"]))
        #expect(!AppManagement.isCaskCommand(["link", "--formula", "xz"]))
    }

    func store(fail: Bool = false, settings: AppSettings = testSettings(), relaunch: (@MainActor @Sendable () -> Void)? = nil) async -> AppStore {
        var deps = Demo.dependencies(.arm64, pace: 0.01, failAppManagement: fail)
        deps.relaunch = relaunch
        let store = AppStore(deps: deps, settings: settings)
        await store.start()
        return store
    }

    @Test func aDiscoverCaskInstallGetsTheExplainerFirst() async throws {
        let store = await store()
        let e = CatalogEntry(kind: .cask, name: "anybar", fullName: "anybar", tap: "homebrew/cask", desc: nil, version: "1.0", bottle: .cask)
        store.startInstall(e)
        let prompt = try #require(store.appManagementPrompt)
        #expect(prompt.reason == .firstUse)
        #expect(prompt.action == .install)
        #expect(store.upgrade == nil)
        store.appManagementDone() // no relaunch available: runs now
        #expect(store.upgrade?.action == .install)
        #expect(store.upgrade?.items.first?.command.display == "brew install --cask homebrew/cask/anybar")
    }

    @Test func aFormulaInstallDoesNot() async throws {
        let store = await store()
        let e = CatalogEntry(kind: .formula, name: "jq", fullName: "jq", tap: "homebrew/core", desc: nil, version: "1.8.1", bottle: .intelbrew)
        store.startInstall(e)
        #expect(store.appManagementPrompt == nil)
        #expect(store.upgrade != nil)
    }

    @Test func adoptGetsTheExplainerAndStillCountsAsStarted() async throws {
        let store = await store()
        let item = AdoptPlanItem(token: "anybar", qualifiedName: "homebrew/cask/anybar", appPath: "/Applications/AnyBar.app",
                                 appVersion: "1.0", caskVersion: "1.0", autoUpdates: false, policy: .automatic)
        #expect(store.startAdopt([item])) // not "didn't start"
        let prompt = try #require(store.appManagementPrompt)
        #expect(prompt.action == .adopt)
        store.appManagementNotNow()
        #expect(store.upgrade?.items.first?.command.display == "brew install --cask --adopt homebrew/cask/anybar")
    }

    @Test func aBlockedInstallIsExplainedWithARetry() async throws {
        let settings = testSettings()
        settings.appManagementExplained = true
        let store = await store(fail: true, settings: settings)
        let e = CatalogEntry(kind: .cask, name: "anybar", fullName: "anybar", tap: "homebrew/cask", desc: nil, version: "1.0", bottle: .cask)
        store.startInstall(e)
        let s = try #require(store.upgrade)
        #expect(await waitUntil(timeout: .seconds(10)) { s.isFinished })
        #expect(s.blockedPackages.map(\.name) == ["anybar"])
        #expect(s.failureKinds == [.appManagement])
        let prompt = try #require(store.appManagementPrompt)
        #expect(prompt.reason == .blocked)
        #expect(prompt.canRetry)
    }

    @Test func doneOffersRelaunchAndKeepsTheOperationForAfter() async throws {
        let settings = testSettings()
        settings.appManagementExplained = true
        let relaunched = Flag()
        let store = await store(fail: true, settings: settings, relaunch: { relaunched.set() })
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        store.startUpgrade([chrome])
        let s = try #require(store.upgrade)
        #expect(await waitUntil(timeout: .seconds(10)) { s.isFinished })
        #expect(await waitUntil { !store.isRefreshing })
        #expect(store.appManagementPrompt?.reason == .blocked)

        store.appManagementDone()
        #expect(store.appManagementPrompt?.stage == .relaunch)
        #expect(store.upgrade === s) // nothing ran yet
        #expect(store.canRelaunch)
        store.appManagementRelaunch()
        #expect(relaunched.value)
        #expect(store.appManagementPrompt == nil)
        let pending = try #require(AppManagementPendingRetry.decode(settings.appManagementPendingRetry))
        #expect(pending.sessionAction == .upgrade)
        #expect(pending.packages.map(\.name) == ["google-chrome"])

        // The next launch (same defaults): offered, never run without a click (1).
        let next = await self.store(settings: settings)
        #expect(await waitUntil { next.appManagementResume != nil })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(next.upgrade == nil)
        #expect(next.showUpgradeSheet)
        #expect(settings.appManagementPendingRetry == nil) // once
        let offer = try #require(next.appManagementResume)
        #expect(offer.action == .upgrade)
        #expect(offer.packages.map(\.name) == ["google-chrome"])
        // Run again: through requestUpgrade, a normal (not retry) session.
        next.appManagementResumeConfirm()
        #expect(next.appManagementResume == nil)
        #expect(next.upgrade?.isRetry == false)
        #expect(next.upgrade?.items.map(\.command.display) == ["brew upgrade --cask homebrew/cask/google-chrome"])
    }

    @Test func cancelOnTheOfferRunsNothing() async throws {
        let settings = testSettings()
        settings.appManagementExplained = true
        let store = await store(settings: settings)
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        store.demoAppManagementResume([chrome])
        #expect(store.appManagementResume != nil)
        store.appManagementResumeCancel()
        #expect(store.appManagementResume == nil)
        #expect(store.upgrade == nil)
        #expect(!store.showUpgradeSheet)
    }

    @Test func onlyAppChangingCasksAreSavedAndAnUninstallOnlyItsRoot() async throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func cask(_ n: String) -> Package {
            var p = CatalogEntry(kind: .cask, name: n, fullName: n, tap: "homebrew/cask", desc: nil, bottle: .cask).asPackage()
            p.appPaths = ["/Applications/\(n).app"]
            p.suitePaths = []
            p.installsPkg = false
            return p
        }
        let formula = CatalogEntry(kind: .formula, name: "xz", fullName: "xz", tap: "homebrew/core", desc: nil, bottle: .intelbrew).asPackage()
        var font = cask("font-x")
        font.appPaths = []
        // (4) formulae and app-less casks are not saved.
        let up = try #require(AppManagementPendingRetry.make(action: .upgrade, targets: [formula, cask("a"), font, cask("b")],
                                                            root: nil, savedAt: t0, compiles: { _ in false }))
        #expect(up.packages.map(\.name) == ["a", "b"])
        #expect(AppManagementPendingRetry.make(action: .upgrade, targets: [formula], root: nil, savedAt: t0, compiles: { _ in false }) == nil)
        // (3) an uninstall keeps only the chosen package, not its orphans (even a cask one).
        let un = try #require(AppManagementPendingRetry.make(action: .uninstall, targets: [cask("root"), formula, cask("orphan")],
                                                            root: nil, savedAt: t0, compiles: { _ in false }))
        #expect(un.packages.map(\.name) == ["root"])
        #expect(AppManagementPendingRetry.make(action: .restore, targets: [cask("a")], root: nil, savedAt: t0, compiles: { _ in false }) == nil)
    }

    @Test func aResumedUninstallGoesThroughItsConfirmation() async throws {
        let settings = testSettings()
        settings.appManagementExplained = true
        let store = await store(settings: settings)
        let c = try #require(store.packages.first { $0.kind == .cask })
        settings.appManagementPendingRetry = AppManagementPendingRetry(action: .uninstall, packages: [c], savedAt: Date()).encoded()
        #expect(store.resumeAppManagementRetry())
        store.appManagementResumeConfirm()
        #expect(store.upgrade == nil) // nothing runs from the offer
        #expect(await waitUntil { store.uninstallCandidate != nil })
        #expect(store.uninstallCandidate?.id == c.id) // the normal confirmation (orphans, rechecks)
        #expect(store.upgrade == nil)
    }

    @Test func continueWithoutRelaunchingRetriesNow() async throws {
        let settings = testSettings()
        settings.appManagementExplained = true
        let store = await store(fail: true, settings: settings, relaunch: {})
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        store.startUpgrade([chrome])
        let s = try #require(store.upgrade)
        #expect(await waitUntil(timeout: .seconds(10)) { s.isFinished })
        store.appManagementDone()
        store.appManagementContinue()
        #expect(store.upgrade !== s)
        #expect(store.upgrade?.isRetry == true)
        #expect(settings.appManagementPendingRetry == nil)
    }

    @Test func pendingRetryResolvesAgainstWhatBrewSays() throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var outdated = CatalogEntry(kind: .cask, name: "a", fullName: "a", tap: "homebrew/cask", desc: nil, bottle: .cask).asPackage()
        outdated.installedVersion = "1"
        outdated.currentVersion = "2"
        outdated.upgradeAvailable = true
        var current = outdated
        current.upgradeAvailable = false
        let up = AppManagementPendingRetry(action: .upgrade, packages: [outdated], savedAt: t0)
        #expect(up.resolve(installed: [outdated], now: t0 + 60)?.packages.map(\.name) == ["a"])
        #expect(up.resolve(installed: [current], now: t0 + 60) == nil) // already upgraded
        #expect(up.resolve(installed: [outdated], now: t0 + 16 * 60) == nil) // too old
        #expect(up.resolve(installed: [outdated], now: t0 - 60) == nil) // clock went back
        // (2) a newer version than the one confirmed, or a changed compile answer: dropped.
        var newer = outdated
        newer.currentVersion = "3"
        #expect(up.resolve(installed: [newer], now: t0 + 60) == nil)
        #expect(up.resolve(installed: [outdated], now: t0 + 60, compiles: { _ in true }) == nil)
        var other = outdated
        other.id = "cask:homebrew/cask/b"
        other.name = "b"
        let two = AppManagementPendingRetry(action: .upgrade, packages: [outdated, other], savedAt: t0)
        let r = try #require(two.resolve(installed: [outdated, { var o = other; o.currentVersion = "9"; return o }()], now: t0 + 60))
        #expect(r.packages.map(\.name) == ["a"])
        #expect(r.dropped == ["b"]) // said so in the sheet
        let saidCompiles = AppManagementPendingRetry(action: .upgrade, packages: [outdated], savedAt: t0, compiling: [outdated.id])
        #expect(saidCompiles.resolve(installed: [outdated], now: t0, compiles: { _ in true })?.packages.count == 1)
        let install = AppManagementPendingRetry(action: .install, packages: [outdated], savedAt: t0)
        #expect(install.resolve(installed: [], now: t0)?.action == .install)
        #expect(install.resolve(installed: [current], now: t0) == nil) // installed meanwhile
        let gone = AppManagementPendingRetry(action: .uninstall, packages: [outdated], savedAt: t0)
        #expect(gone.resolve(installed: [], now: t0) == nil)
        let restore = AppManagementPendingRetry(action: .restore, packages: [outdated], savedAt: t0)
        #expect(restore.resolve(installed: [], now: t0) == nil)
        #expect(AppManagementPendingRetry.decode(up.encoded()) == up)
        #expect(AppManagementPendingRetry.decode(Data("junk".utf8)) == nil)
    }

    @Test func relaunchCommandWaitsThenOpensTheBundle() throws {
        let c = AppManagement.relaunchCommand(bundlePath: "/Applications/My Tankard.app", pid: 4242)
        #expect(c.executable == "/bin/sh")
        #expect(c.arguments.count == 4)
        #expect(c.arguments[0] == "-c")
        #expect(c.arguments[1].hasSuffix("exec /usr/bin/open -n \"$0\""))
        #expect(c.arguments[2] == "/Applications/My Tankard.app") // $0: never spliced into the script
        #expect(c.arguments[3] == "4242")
        #expect(AppManagement.canRelaunch(bundlePath: "/Applications/Tankard.app"))
        #expect(!AppManagement.canRelaunch(bundlePath: "/Users/me/tankard/.build/debug"))

        // The script as is, with `open` swapped for echo: a gone pid doesn't
        // wait, and a path with spaces arrives as one argument.
        let script = c.arguments[1].replacingOccurrences(of: "exec /usr/bin/open -n", with: "printf %s")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.executable)
        p.arguments = ["-c", script, c.arguments[2], "999999"]
        let out = Pipe()
        p.standardOutput = out
        let start = Date()
        try p.run()
        p.waitUntilExit()
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "/Applications/My Tankard.app")
    }

    @Test func probeWritesAndRemovesItsFileOnlyInABrewApp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)/Fake.app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        #expect(AppManagementProbe.run(appPath: dir.path) == .allowed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty) // nothing left behind
        // A leftover from an interrupted probe is removed too.
        FileManager.default.createFile(atPath: dir.appendingPathComponent(AppManagementProbe.fileName).path, contents: nil)
        #expect(AppManagementProbe.run(appPath: dir.path) == .allowed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(AppManagementProbe.run(appPath: dir.path + "-gone") == .unknown)

        var cask = CatalogEntry(kind: .cask, name: "a", fullName: "a", tap: "homebrew/cask", desc: nil, bottle: .cask).asPackage()
        cask.appPaths = ["/opt/homebrew/Caskroom/a/1/A.app", "/Applications/A.app"]
        var formula = cask
        formula.kind = .formula
        #expect(AppManagementProbe.target([cask], exists: { _ in true }) == "/Applications/A.app")
        #expect(AppManagementProbe.target([formula], exists: { _ in true }) == nil)
        #expect(AppManagementProbe.target([cask], exists: { _ in false }) == nil)
        var none = cask
        none.appPaths = nil // an adopt or Discover row: never probed
        #expect(AppManagementProbe.target([none], exists: { _ in true }) == nil)
    }

    @Test func autoUpdateBlockSaysSoInTheNotificationAndHistory() {
        var run = AutoUpdateRun(startedAt: Date(), failed: [.init(name: "firefox", isCask: true, detail: BrewFailureKind.appManagement.title)])
        run.appManagement = ["firefox"]
        let body = run.notification?.body ?? ""
        #expect(body.contains("App Management"))
        let old = try? JSONDecoder().decode(AutoUpdateRun.self, from: JSONEncoder().encode(AutoUpdateRun(startedAt: Date())))
        #expect(old?.appManagement == nil) // logs from before 0.8.1 still load

        let e = HistoryEntry(startedAt: Date(), duration: 1, command: "brew install --cask homebrew/cask/firefox",
                             arguments: ["install", "--cask", "homebrew/cask/firefox"], outcome: .failed, exitCode: 1,
                             failure: BrewFailureKind.appManagement.rawValue)
        #expect(!e.canRetry)
        #expect(e.rerunHint?.contains("App Management") == true)
    }
}
