import CryptoKit
import Foundation
import Observation
import Testing
import TankardCore
@testable import TankardAppModel

/// `brew info` answers that can change between reads (a background check
/// that finds a new upgrade).
final class MutableInfoRunner: CommandRunning, @unchecked Sendable {
    let log: CallLog
    private let lock = NSLock()
    private var _info: Data
    var info: Data {
        get { lock.withLock { _info } }
        set { lock.withLock { _info = newValue } }
    }

    init(log: CallLog, info: Data) {
        self.log = log
        _info = info
    }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        guard executable.hasSuffix("brew") else { return ProcessResult(exitCode: 128, stdout: Data(), stderr: Data()) }
        log.add(arguments)
        return ProcessResult(exitCode: 0, stdout: info, stderr: Data())
    }
}

@MainActor
final class FakeNotifier: UpgradeNotifying {
    var posted: [UpgradeNotificationDiff.Message] = []
    var authorizationRequests = 0
    func requestAuthorization() async -> Bool { authorizationRequests += 1; return true }
    func post(_ message: UpgradeNotificationDiff.Message) { posted.append(message) }
}

/// Set from an observation onChange (a @Sendable closure).
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}

@MainActor func testSettings(_ name: String = "net.mindtricks.tankard.tests.\(UUID().uuidString)") -> AppSettings {
    AppSettings.ephemeral(name)
}

/// Test settings with "Scan for vulnerabilities when refreshing" on (0.4:
/// off by default), for tests about what a scan finds.
@MainActor func scanningSettings() -> AppSettings {
    let s = testSettings()
    InsightSettings(defaults: s.defaults).scanVulnerabilitiesOnRefresh = true
    return s
}

// MARK: menu bar

@MainActor
struct MenuBarTests {
    func intel() async throws -> [Package] {
        try await makeClient(FakeInfoRunner(log: CallLog(), info: demoIntelInfo())).status().packages
    }

    @Test func countModel() async throws {
        let s = MenuBarSummary(packages: try await intel())
        #expect(s.count == 5)
        #expect(s.title == "5 upgrades ready")
        #expect(s.badge == "5")
        #expect(s.rows.map(\.name) == ["openssl@4", "python@3.15", "ruby", "sqlite", "xz"])
        #expect(s.rows.first { $0.name == "ruby" }?.compiles == true)
        #expect(s.rows.filter(\.compiles).count == 1)
        #expect(s.rows.first { $0.name == "xz" }?.versions == "5.8.3 → 5.8.4")
        #expect(s.moreCount == 0)
    }

    @Test func emptyAndNoData() async throws {
        let none = MenuBarSummary(packages: nil)
        #expect(none.title == "No data yet")
        #expect(none.badge == nil)
        let current = try await intel().map { p -> Package in var q = p; q.upgradeAvailable = false; return q }
        let s = MenuBarSummary(packages: current)
        #expect(s.title == "Everything is up to date")
        #expect(s.badge == nil)
        #expect(s.rows.isEmpty)
    }

    @Test func longListsSayHowManyMore() async throws {
        let base = try #require(try await intel().first { $0.upgradeAvailable })
        let many = (0..<15).map { i -> Package in var p = base; p.id = "formula:homebrew/core/p\(i)"; p.name = "p\(i)"; return p }
        let s = MenuBarSummary(packages: many)
        #expect(s.count == 15)
        #expect(s.rows.count == MenuBarSummary.maxRows)
        #expect(s.moreCount == 7)
        #expect(s.moreText == "and 7 more…")
        #expect(MenuBarSummary(packages: [base]).title == "1 upgrade ready")
    }

    func upgrades(_ n: Int) async throws -> [Package] {
        let base = try #require(try await intel().first { $0.upgradeAvailable })
        return (0..<n).map { i -> Package in var p = base; p.id = "formula:homebrew/core/p\(i)"; p.name = "p\(i)"; return p }
    }

    /// 0.5: at most 8 rows; "and N more…" only past 8.
    @Test func eightRowsThenMore() async throws {
        #expect(MenuBarSummary.maxRows == 8)
        let eight = MenuBarSummary(packages: try await upgrades(8))
        #expect(eight.rows.count == 8)
        #expect(eight.moreCount == 0)
        #expect(eight.moreText == nil)
        let nine = MenuBarSummary(packages: try await upgrades(9))
        #expect(nine.rows.count == 8)
        #expect(nine.moreCount == 1)
        #expect(nine.moreText == "and 1 more…")
        // Rows are the first 8 by name; the rest are counted, not listed.
        #expect(nine.rows.map(\.name) == ["p0", "p1", "p2", "p3", "p4", "p5", "p6", "p7"])
    }

    /// 0.5: the badge spells out up to 99, then "99+".
    @Test func badgeCapsAt99Plus() async throws {
        #expect(MenuBarSummary(packages: try await upgrades(1)).badge == "1")
        #expect(MenuBarSummary(packages: try await upgrades(99)).badge == "99")
        let many = MenuBarSummary(packages: try await upgrades(100))
        #expect(many.badge == "99+")
        #expect(many.title == "100 upgrades ready")
        #expect(many.moreCount == 92)
    }

    /// 0.5: "and N more…" opens the Installed tab on the Upgrades filter,
    /// clearing a search; a second click writes (and notifies) nothing.
    @Test func moreShowsTheUpgradesList() {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        store.tab = .discover
        store.filter = .pinned
        store.search = "xz"
        store.showUpgrades()
        #expect(store.tab == .installed)
        #expect(store.filter == .upgrades)
        #expect(store.search.isEmpty)
        let notified = Flag()
        withObservationTracking { _ = (store.tab, store.filter, store.search) } onChange: { notified.set() }
        store.showUpgrades()
        #expect(!notified.value)
    }
}

// MARK: notifications and the schedule

@MainActor
struct NotificationDiffTests {
    func pkgs() async throws -> [Package] {
        try await makeClient(FakeInfoRunner(log: CallLog(), info: demoIntelInfo())).status().packages
    }

    @Test func onlyAGrowingSetNotifies() async throws {
        let all = try await pkgs()
        let keys = UpgradeNotificationDiff.keys(all)
        #expect(keys.count == 5)
        #expect(keys.contains("formula:homebrew/core/xz@5.8.4"))
        // First check: baseline only.
        #expect(UpgradeNotificationDiff.decide(previous: nil, current: keys, packages: all) == nil)
        // Same set: nothing.
        #expect(UpgradeNotificationDiff.decide(previous: keys, current: keys, packages: all) == nil)
        // Shrunk (something got upgraded): nothing.
        let fewer = keys.filter { !$0.contains("/xz@") }
        #expect(UpgradeNotificationDiff.decide(previous: keys, current: fewer, packages: all) == nil)
        // Grew: one notification naming only what's new.
        let m = try #require(UpgradeNotificationDiff.decide(previous: fewer, current: keys, packages: all))
        #expect(m.title == "5 upgrades ready")
        #expect(m.body == "New: xz")
        #expect(m.newKeys == ["formula:homebrew/core/xz@5.8.4"])
    }

    @Test func aNewerVersionOfAKnownUpgradeIsNew() async throws {
        var all = try await pkgs()
        let before = UpgradeNotificationDiff.keys(all)
        let i = try #require(all.firstIndex { $0.name == "sqlite" })
        all[i].currentVersion = "3.56.0"
        let m = try #require(UpgradeNotificationDiff.decide(previous: before, current: UpgradeNotificationDiff.keys(all), packages: all))
        #expect(m.body == "New: sqlite")
    }

    @Test func schedule() {
        let launch = Date(timeIntervalSince1970: 1_000_000)
        let s = BackgroundSchedule(intervalHours: 6)
        #expect(s.interval == 6 * 3600)
        #expect(BackgroundSchedule(intervalHours: 0).intervalHours == 1)
        #expect(BackgroundSchedule(intervalHours: 500).intervalHours == 48)
        // Never checked: shortly after launch.
        #expect(s.nextCheck(lastCheck: nil, launchedAt: launch) == launch.addingTimeInterval(120))
        // Checked an hour before launch: five hours after launch.
        let last = launch.addingTimeInterval(-3600)
        #expect(s.nextCheck(lastCheck: last, launchedAt: launch) == launch.addingTimeInterval(5 * 3600))
        // Overdue (the Mac slept through it): right after the startup delay.
        #expect(s.nextCheck(lastCheck: launch.addingTimeInterval(-86400), launchedAt: launch) == launch.addingTimeInterval(120))
        #expect(!s.isDue(lastCheck: last, launchedAt: launch, now: launch.addingTimeInterval(4 * 3600)))
        #expect(s.isDue(lastCheck: last, launchedAt: launch, now: launch.addingTimeInterval(5 * 3600)))
        #expect(BackgroundSchedule(intervalHours: 1).nextCheck(lastCheck: launch, launchedAt: launch) == launch.addingTimeInterval(3600))
    }

    @Test func settingsPersistWithDefaults() {
        let name = "net.mindtricks.tankard.tests.\(UUID().uuidString)"
        let a = testSettings(name)
        #expect(a.showMenuBarIcon)
        #expect(!a.notifyNewUpgrades)
        #expect(a.checkIntervalHours == 6)
        #expect(!a.appManagementExplained)
        a.showMenuBarIcon = false
        a.checkIntervalHours = 100
        #expect(a.checkIntervalHours == 48)
        a.notifiedUpgrades = ["x@1"]
        a.notifyNewUpgrades = true
        #expect(a.notifiedUpgrades == nil) // turning it on starts a fresh baseline
        a.notifiedUpgrades = ["y@2"]
        a.appManagementExplained = true
        let b = AppSettings(defaults: UserDefaults(suiteName: name)!)
        #expect(!b.showMenuBarIcon)
        #expect(b.notifyNewUpgrades)
        #expect(b.checkIntervalHours == 48)
        #expect(b.notifiedUpgrades == ["y@2"])
        #expect(b.appManagementExplained)
        UserDefaults(suiteName: name)!.removePersistentDomain(forName: name)
    }

    /// 0.3.0's launch crash: SwiftUI writes `MenuBarExtra(isInserted:)` back
    /// with an unchanged value while building scenes. If that write notifies
    /// observers, App.body (which reads the setting) re-runs and the binding
    /// is written again, forever. An unchanged write must notify nothing.
    @Test func unchangedMenuBarWriteNotifiesNothing() {
        let name = "net.mindtricks.tankard.tests.\(UUID().uuidString)"
        let s = testSettings(name)
        defer { UserDefaults(suiteName: name)!.removePersistentDomain(forName: name) }
        for value in [true, false] {
            if s.showMenuBarIcon != value { s.showMenuBarIcon = value }
            let notified = Flag()
            withObservationTracking { _ = s.showMenuBarIcon } onChange: { notified.set() }
            s.showMenuBarIcon = value
            #expect(!notified.value, "writing \(value) over \(value) notified observers")
        }
        // A real change still notifies and persists.
        let notified = Flag()
        withObservationTracking { _ = s.showMenuBarIcon } onChange: { notified.set() }
        s.showMenuBarIcon = true
        #expect(notified.value)
        #expect(AppSettings(defaults: UserDefaults(suiteName: name)!).showMenuBarIcon)
    }

    /// The same for the theme: an unchanged write neither notifies nor
    /// re-applies NSApp.appearance (onChange).
    @Test func unchangedThemeWriteNotifiesNothing() {
        let name = "net.mindtricks.tankard.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let a = AppearanceSettings(defaults: d)
        var applied: [AppTheme] = []
        a.onChange = { applied.append($0) }
        let notified = Flag()
        withObservationTracking { _ = a.theme } onChange: { notified.set() }
        a.theme = a.theme
        #expect(!notified.value)
        #expect(applied.isEmpty)
        a.theme = .dracula
        #expect(notified.value)
        #expect(applied == [.dracula])
        #expect(AppearanceSettings(defaults: d).theme == .dracula)
        // preview() of the current theme changes nothing, and the next real
        // choice still saves.
        a.preview(.dracula)
        a.theme = .tankard
        #expect(AppearanceSettings(defaults: d).theme == .tankard)
    }

    @Test func backgroundCheckRunsUpdateAndNotifiesOnlyOnNewUpgrades() async throws {
        let log = CallLog()
        let runner = MutableInfoRunner(log: log, info: Demo.currentInfo(.intelbrew, base: Demo.fixtureInfo(.intelbrew), upgraded: ["xz"]))
        let client = makeClient(runner)
        let stream = FakeStreamRunner(log: log) { _, _ in 0 }
        let settings = testSettings()
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: stream, cache: nil, logURL: nil),
                             settings: settings)
        await store.start()
        let notifier = FakeNotifier()
        let launched = Date().addingTimeInterval(-3600)
        let checker = BackgroundChecker(store: store, settings: settings, notifier: notifier, launchedAt: launched)

        // Off by default: a tick does nothing.
        #expect(await checker.tick() == 300)
        #expect(log.count("update") == 0)

        settings.notifyNewUpgrades = true
        await checker.tick() // due (never checked): brew update, read, baseline
        #expect(log.count("update") == 1)
        #expect(settings.lastBackgroundCheck != nil)
        #expect(settings.notifiedUpgrades?.count == 4)
        #expect(notifier.posted.isEmpty)

        // Not due again for 6 hours.
        let wait = await checker.tick()
        #expect(wait > 5 * 3600)
        #expect(log.count("update") == 1)

        // Same set: no notification.
        await checker.runCheck()
        #expect(notifier.posted.isEmpty)

        // xz's upgrade appears: one notification.
        runner.info = demoIntelInfo()
        await checker.runCheck()
        #expect(log.count("update") == 3)
        #expect(notifier.posted.count == 1)
        #expect(notifier.posted.first?.body == "New: xz")
        #expect(settings.notifiedUpgrades?.count == 5)
        await checker.runCheck()
        #expect(notifier.posted.count == 1)
    }
}

// MARK: upgrade plan (compile warnings)

@MainActor
struct UpgradePlanTests {
    func rig() async throws -> (AppStore, CallLog) {
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: log) { _, out in out(Data("ok\n".utf8)); return 0 }
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil))
        await store.start()
        return (store, log)
    }

    @Test func planShowsCompilesAndCanSkipThem() async throws {
        let (store, log) = try await rig()
        store.requestUpgrade()
        let plan = try #require(store.upgradePlan)
        #expect(store.showUpgradeSheet)
        #expect(store.upgrade == nil) // nothing started yet
        #expect(plan.rows.count == 5)
        #expect(plan.compiling.map(\.name) == ["ruby"])
        #expect(plan.rows.first { $0.package.name == "ruby" }?.warning?.label == "No bottle: will compile from source")
        #expect(plan.rows.filter { $0.warning == nil }.count == 4)
        #expect(plan.startTitle == "Upgrade 5")
        store.setPlanSkipCompiling(true)
        #expect(store.upgradePlan?.startTitle == "Upgrade 4 (skip 1)")
        store.confirmUpgradePlan()
        #expect(store.upgradePlan == nil)
        let session = try #require(store.upgrade)
        #expect(session.items.map(\.package.name).sorted() == ["openssl@4", "python@3.15", "sqlite", "xz"])
        #expect(await waitUntil { session.isFinished })
        #expect(!log.calls.contains(["upgrade", "--formula", "homebrew/core/ruby"]))
    }

    @Test func nothingCompilingStartsAtOnce() async throws {
        let (store, _) = try await rig()
        let xz = try #require(store.packages.first { $0.name == "xz" })
        store.requestUpgrade([xz])
        #expect(store.upgradePlan == nil)
        #expect(store.upgrade?.items.count == 1)
    }

    @Test func skipCompilingFromTheFilter() async throws {
        let (store, _) = try await rig()
        store.startUpgradeSkippingCompiles()
        #expect(store.upgrade?.items.count == 4)
        #expect(store.upgrade?.items.contains { $0.package.name == "ruby" } == false)
    }

    @Test func cancelLeavesNothingRunning() async throws {
        let (store, log) = try await rig()
        store.requestUpgrade()
        store.cancelUpgradePlan()
        #expect(store.upgradePlan == nil)
        #expect(!store.showUpgradeSheet)
        #expect(log.count("upgrade") == 0)
    }
}

// MARK: replace with bottle

@MainActor
struct ReplaceWithBottleTests {
    @Test func commandAndFilter() async throws {
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: log) { _, _ in 0 }
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil))
        await store.start()
        #expect(store.bottleReplaceable.map(\.name) == ["vim"])
        #expect(store.count(.bottleAvailable) == 1)
        store.filter = .bottleAvailable
        #expect(store.visiblePackages.map(\.name) == ["vim"])
        let vim = try #require(store.bottleReplaceable.first)
        #expect(vim.subtitle == "Bottle available (Intelbrew)")
        #expect(BrewCommands.replaceWithBottleArguments(for: vim) == ["reinstall", "--force-bottle", "--formula", "homebrew/core/vim"])
        // A package that isn't eligible is dropped, not run.
        let xz = try #require(store.packages.first { $0.name == "xz" })
        store.startReplaceWithBottle([xz])
        #expect(store.upgrade == nil)
        store.startReplaceWithBottle()
        let session = try #require(store.upgrade)
        #expect(session.action == .replaceBottle)
        #expect(session.title == "Reinstalling vim from a bottle")
        #expect(session.subtitle == "Swaps source builds for Intelbrew bottles")
        #expect(session.items[0].command.display == "brew reinstall --force-bottle --formula homebrew/core/vim")
        #expect(session.items[0].command.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(await waitUntil { session.isFinished })
        #expect(session.title == "Reinstall complete")
        #expect(session.statusLine == "1 reinstalled")
        #expect(log.calls.contains(["reinstall", "--force-bottle", "--formula", "homebrew/core/vim"]))
    }

    @Test func demoEndToEnd() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0.01))
        await store.start()
        store.startReplaceWithBottle()
        let session = try #require(store.upgrade)
        #expect(await waitUntil(timeout: .seconds(10)) { session.isFinished })
        #expect(await waitUntil { !store.isRefreshing && store.bottleReplaceable.isEmpty })
        let vim = try #require(store.packages.first { $0.name == "vim" })
        #expect(vim.status == .bottle)
        #expect(vim.pouredFromBottle == true)
    }
}

// MARK: cleanup

@MainActor
struct CleanupStoreTests {
    @Test func dryRunThenCleanupThroughTheQueue() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0.01))
        await store.start()
        store.openCleanup()
        let c = try #require(store.cleanup)
        #expect(store.showCleanupSheet)
        #expect(await waitUntil { c.phase == .ready && !c.measuringCache })
        #expect(c.dryRun?.summaryText == "187.6MB")
        #expect(c.dryRun?.items.count == 10)
        #expect(c.dryRun?.bytes(of: .oldVersion) == 102_800_000)
        #expect(c.cachePath == "/Users/demo/Library/Caches/Homebrew")
        #expect(c.cacheBytes == Int64(412_388) * 1024)
        #expect(c.command == "brew cleanup")
        #expect(c.problem == nil)
        store.startCleanup()
        #expect(!store.showCleanupSheet)
        let session = try #require(store.upgrade)
        #expect(session.action == .cleanup)
        #expect(session.title == "Cleaning up")
        #expect(session.items[0].command.arguments == ["cleanup"])
        #expect(session.items[0].command.display == "brew cleanup")
        #expect(await waitUntil(timeout: .seconds(10)) { session.isFinished })
        #expect(session.title == "Cleanup complete")
        #expect(session.log.lines.contains { $0.hasPrefix("Removing: /usr/local/Cellar/python@3.15/3.15.0...") })
    }

    @Test func dryRunReadsTheRealCommands() async throws {
        let calls = CallLog()
        let runner = FakeRunnerForCleanup(log: calls)
        let client = makeClient(runner)
        let c = CleanupStore(client: client, env: ["PATH": "/usr/bin"])
        await c.load()
        #expect(calls.calls == [["/usr/local/bin/brew", "--cache"], ["/usr/local/bin/brew", "cleanup", "-n"], ["/usr/bin/du", "-sk", "/Users/test/Library/Caches/Homebrew"]]
                || calls.calls == [["/usr/local/bin/brew", "--cache"], ["/usr/bin/du", "-sk", "/Users/test/Library/Caches/Homebrew"], ["/usr/local/bin/brew", "cleanup", "-n"]])
        #expect(c.exitCode == 1)
        #expect(c.problem == "Error: Refusing to load formula homebrew/core/hello from untrusted tap homebrew/core.")
        #expect(c.dryRun?.items.count == 1)
        #expect(c.cacheBytes == 2048)
    }
}

final class FakeRunnerForCleanup: CommandRunning, @unchecked Sendable {
    let log: CallLog
    init(log: CallLog) { self.log = log }
    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        log.add([executable] + arguments)
        func out(_ s: String, _ code: Int32 = 0) -> ProcessResult { ProcessResult(exitCode: code, stdout: Data(s.utf8), stderr: Data()) }
        switch arguments {
        case ["--cache"]: return out("/Users/test/Library/Caches/Homebrew\n")
        case ["cleanup", "-n"]:
            return ProcessResult(exitCode: 1, stdout: Data("Would remove: /Users/test/Library/Caches/Homebrew/x--1.tar.gz (1MB)\n".utf8),
                                 stderr: Data("Error: Refusing to load formula homebrew/core/hello from untrusted tap homebrew/core.\n".utf8))
        default: return out("2\t/Users/test/Library/Caches/Homebrew\n")
        }
    }
}

// MARK: App Management

@MainActor
struct AppManagementTests {
    @Test func matcher() {
        #expect(AppManagement.isPermissionBlock([
            "==> Upgrading google-chrome",
            "Error: Cannot change the ownership of '/Applications/Google Chrome.app' because your terminal does not have App Management permissions.",
        ]))
        #expect(AppManagement.isPermissionBlock(["Warning: Your terminal does not have App Management permissions, so Homebrew will delete and reinstall the app."]))
        #expect(AppManagement.isPermissionBlock(["Error: Operation not permitted @ rb_file_s_rename - (/Applications/Firefox.app, /opt/homebrew/Caskroom/firefox/.metadata/x)"]))
        #expect(AppManagement.isPermissionBlock(["mv: rename /Applications/iTerm.app to /private/tmp/iTerm.app: Operation not permitted"]))
        #expect(AppManagement.isPermissionBlock(["“Tankard” was prevented from modifying apps on your Mac."]))
        #expect(!AppManagement.isPermissionBlock(["Error: Operation not permitted @ dir_s_mkdir - /usr/local/Cellar/x"]))
        #expect(!AppManagement.isPermissionBlock(["==> Pouring xz--5.8.4.sonoma.bottle.tar.gz", "Error: Permission denied"]))
        #expect(!AppManagement.isPermissionBlock([String]()))
        #expect(AppManagement.settingsURL.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")
        #expect(AppManagement.steps().count == 3)
    }

    @Test func onlyCaskUpgradesAndUninstalls() {
        let cask = CatalogEntry(kind: .cask, name: "firefox", fullName: "firefox", tap: "homebrew/cask", desc: nil, bottle: .cask).asPackage()
        let formula = CatalogEntry(kind: .formula, name: "xz", fullName: "xz", tap: "homebrew/core", desc: nil, bottle: .intelbrew).asPackage()
        #expect(AppManagement.modifiesApps(.upgrade, cask))
        #expect(AppManagement.modifiesApps(.uninstall, cask))
        #expect(!AppManagement.modifiesApps(.install, cask))
        #expect(!AppManagement.modifiesApps(.upgrade, formula))
        #expect(!AppManagement.modifiesApps(.uninstall, formula))
        #expect(!AppManagement.modifiesApps(.replaceBottle, formula))
        #expect(!AppManagement.modifiesApps(.cleanup, Package.command("brew cleanup")))
    }

    func arm64Store(fail: Bool, settings: AppSettings) async -> AppStore {
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0.01, failAppManagement: fail), settings: settings)
        await store.start()
        return store
    }

    @Test func explainerShowsOnceBeforeTheFirstCaskChange() async throws {
        let settings = testSettings()
        let store = await arm64Store(fail: false, settings: settings)
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        // Formulae never trigger it.
        let formula = try #require(store.packages.first { $0.kind == .formula && $0.upgradeAvailable })
        store.startUpgrade([formula])
        #expect(store.appManagementPrompt == nil)
        let first = try #require(store.upgrade)
        #expect(await waitUntil(timeout: .seconds(10)) { first.isFinished })
        #expect(await waitUntil { !store.isRefreshing })
        store.closeUpgrade()

        store.startUpgrade([chrome])
        let prompt = try #require(store.appManagementPrompt)
        #expect(prompt.reason == .firstUse)
        #expect(prompt.packages.map(\.name) == ["google-chrome"])
        #expect(store.upgrade == nil) // waits for the user
        #expect(store.showUpgradeSheet)
        store.appManagementDone()
        #expect(settings.appManagementExplained)
        #expect(store.appManagementPrompt == nil)
        let session = try #require(store.upgrade)
        #expect(session.items.map(\.package.name) == ["google-chrome"])
        #expect(await waitUntil(timeout: .seconds(10)) { session.isFinished })
        #expect(await waitUntil { !store.isRefreshing })
        store.closeUpgrade()

        // Remembered: the next cask change starts straight away.
        let other = try #require(store.packages.first { $0.kind == .cask })
        store.requestUninstall(other)
        store.startUninstall(other)
        #expect(store.appManagementPrompt == nil)
        #expect(store.upgrade != nil)
    }

    @Test func notNowStillRunsWhatWasAsked() async throws {
        let settings = testSettings()
        let store = await arm64Store(fail: false, settings: settings)
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        store.startUpgrade([chrome])
        #expect(store.appManagementPrompt?.reason == .firstUse)
        store.appManagementNotNow()
        #expect(settings.appManagementExplained)
        #expect(store.upgrade?.items.first?.package.name == "google-chrome")
    }

    @Test func aBlockedCaskStepOffersOneRetryThroughTheQueue() async throws {
        let settings = testSettings()
        settings.appManagementExplained = true
        let store = await arm64Store(fail: true, settings: settings)
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        store.startUpgrade([chrome])
        let first = try #require(store.upgrade)
        #expect(await waitUntil(timeout: .seconds(10)) { first.isFinished })
        #expect(first.failedItems.count == 1)
        #expect(first.blockedPackages.map(\.name) == ["google-chrome"])
        let prompt = try #require(store.appManagementPrompt)
        #expect(prompt.reason == .blocked)
        #expect(store.showUpgradeSheet)

        store.appManagementDone()
        let retry = try #require(store.upgrade)
        #expect(retry !== first)
        #expect(retry.isRetry)
        #expect(retry.items.map(\.command.display) == ["brew upgrade --cask homebrew/cask/google-chrome"])
        #expect(await waitUntil(timeout: .seconds(10)) { retry.isFinished })
        #expect(retry.failedItems.isEmpty) // the demo lets the second attempt through
        #expect(store.appManagementPrompt == nil)
    }

    @Test func aRetryThatFailsAgainDoesNotLoop() async throws {
        let log = CallLog()
        let client = BrewClient(installation: BrewInstallation(brewPath: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew", repository: "/opt/homebrew"),
                                platform: BottlePlatform(arch: .arm64, macOSVersion: "27", cellar: "/opt/homebrew/Cellar"),
                                runner: FakeInfoRunner(log: log, info: Demo.fixtureInfo(.arm64)),
                                sources: EnvironmentSources(process: ["HOME": "/Users/t"]), fileExists: { _ in false })
        let runner = FakeStreamRunner(log: log) { _, out in
            out(Data("Error: Operation not permitted @ rb_file_s_rename - (/Applications/Google Chrome.app, /tmp/x)\n".utf8))
            return 1
        }
        let settings = testSettings()
        settings.appManagementExplained = true
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil), settings: settings)
        await store.start()
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        store.startUpgrade([chrome])
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        #expect(store.appManagementPrompt?.reason == .blocked)
        store.appManagementDone()
        #expect(await waitUntil { store.upgrade?.isRetry == true && store.upgrade?.isFinished == true })
        #expect(store.appManagementPrompt == nil) // once only
        #expect(log.calls.filter { $0 == ["upgrade", "--cask", "homebrew/cask/google-chrome"] }.count == 2)

        // A formula failing with similar words never triggers it.
        store.closeUpgrade()
        #expect(await waitUntil { !store.isRefreshing })
        let formula = try #require(store.packages.first { $0.kind == .formula && $0.upgradeAvailable })
        store.startUpgrade([formula])
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        #expect(store.upgrade?.blockedPackages.isEmpty == true)
        #expect(store.appManagementPrompt == nil)
    }
}

// MARK: Discover bottle filter, ranking, dependency compiles

@MainActor
struct DiscoverBottleTests {
    func intelbrewDiscover() async throws -> (AppStore, DiscoverStore) {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0.01))
        await store.start()
        let d = try #require(store.openDiscover())
        await d.activate()
        return (store, d)
    }

    @Test func chipIsOnInIntelbrewModeWithACount() async throws {
        let (_, d) = try await intelbrewDiscover()
        #expect(d.bottledOnly)
        #expect(d.bottledChipTitle == "Has Intel bottle")
        // Every formula's bottle is known from the tap scan, before brew info.
        #expect(d.formulaCount == 171)
        #expect(d.bottledCount == 114)
        #expect(d.bottledCountText == "114 of 171 bottled")
        d.query = "ffmpeg"
        await d.searchNow()
        #expect(d.results.allSatisfy { $0.bottle != .fromSource })
        #expect(!d.results.contains { $0.name == "ffmpeg@8" })
        d.bottledOnly = false
        #expect(await waitUntil { d.results.contains { $0.name == "ffmpeg@8" } })
    }

    @Test func rankingPrefersBottlesWithinATier() async throws {
        let (_, d) = try await intelbrewDiscover()
        d.bottledOnly = false
        d.query = "ffmpeg"
        await d.searchNow()
        let names = d.results.map(\.name)
        #expect(names.first == "ffmpeg") // exact name first
        // Name-prefix tier: bottled ffmpeg@4, @5, ffmpeg2theora before the compiling ones.
        let prefix = Array(names.dropFirst())
        let firstCompile = try #require(prefix.firstIndex { n in d.results.first { $0.name == n }?.bottle == .fromSource })
        #expect(prefix[..<firstCompile].allSatisfy { n in d.results.first { $0.name == n }?.bottle != .fromSource })
        #expect(prefix[firstCompile...].allSatisfy { n in d.results.first { $0.name == n }?.bottle == .fromSource })
        #expect(Set(prefix[..<firstCompile]) == ["ffmpeg2theora", "ffmpeg@4", "ffmpeg@5"])
    }

    @Test func dependencyCompileCount() async throws {
        let (store, d) = try await intelbrewDiscover()
        d.bottledOnly = false
        let red = try #require(d.entry(named: "node-red"))
        #expect(red.bottle == .fromSource)
        #expect(store.deps.classifier.installWarning(red)?.label == "No bottle: compiles")
        let r = d.dependenciesThatCompile(red, installedIDs: store.installedIDs)
        #expect(r.compiling.map(\.name) == ["node"])
        // A bottled formula that needs an unbottled one still pulls a compile.
        let schema = try #require(d.entry(named: "generate-json-schema"))
        #expect(d.dependenciesThatCompile(schema, installedIDs: store.installedIDs).compiling.map(\.name) == ["node"])
        // Installed dependencies don't count.
        #expect(d.dependenciesThatCompile(red, installedIDs: store.installedIDs.union([try #require(d.entry(named: "node")).id])).compiling.isEmpty)
        #expect(red.badgeLabel == "No bottle: compiles")
        #expect(red.badgeKind == .source)
    }

    @Test func normalModeChipIsOff() async throws {
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0.01))
        await store.start()
        let d = try #require(store.openDiscover())
        #expect(!d.bottledOnly)
        #expect(d.bottledChipTitle == "Has bottle")
    }
}

// MARK: About

struct AboutTests {
    @Test func versionStringHasNoBuildNumber() {
        #expect(AboutInfo.versionLine(short: "0.3.0", build: "12") == "Version 0.3.0")
        #expect(AboutInfo.versionLine(short: "0.3.0", build: "0.3.0") == "Version 0.3.0")
        #expect(AboutInfo.versionLine(short: nil, build: "0.3.0") == "Version 0.3.0")
        #expect(AboutInfo.versionLine(short: "", build: nil) == "Version \(TankardVersion.string)")
        let v = AboutInfo.panelVersions(bundle: ["CFBundleShortVersionString": "0.3.0", "CFBundleVersion": "12"])
        #expect(v.application == "0.3.0")
        #expect(v.build == "")
        #expect(TankardVersion.string == "0.6.1")
        #expect(AboutInfo.author == "Made by d4rkwyng")
        #expect(AboutInfo.copyright == "© 2026 d4rkwyng")
        #expect(AboutInfo.newIssue.absoluteString == "https://github.com/d4rkwyng/tankard/issues/new")
        #expect(AboutInfo.homebrewLine.contains("brew.sh"))
        #expect(AboutInfo.notAffiliated == "Not affiliated with or endorsed by the Homebrew project.")
        // Short enough for the About panel without wrapping.
        for line in [AboutInfo.homebrewLine, AboutInfo.homebrewCopyright, AboutInfo.notAffiliated, AboutInfo.intelbrewBottlesLine] {
            #expect(line.count <= 56)
        }
    }
}

// MARK: Intelbrew build times

final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _n = 0
    private var _responses: [(Data, Int)]
    init(_ responses: [(Data, Int)]) { _responses = responses }
    var count: Int { lock.withLock { _n } }
    func next() throws -> (Data, Int) {
        try lock.withLock {
            _n += 1
            guard !_responses.isEmpty else { throw URLError(.notConnectedToInternet) }
            return _responses.count == 1 ? _responses[0] : _responses.removeFirst()
        }
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _t = Date(timeIntervalSince1970: 2_000_000_000)
    var now: Date { lock.withLock { _t } }
    func advance(_ s: TimeInterval) { lock.withLock { _t += s } }
}

struct BuildTimesTests {
    /// Schema 1, as the Intelbrew builder publishes it.
    static let fixture = Data("""
    {"schema":1,"generated_at":"2026-11-17T06:12:00Z","measured_on":"intelbrew-builder (macOS 14, x86_64)",
     "formulae":{
       "ruby":{"median_seconds":1412.4,"samples":5,"last_seconds":1388.0,"last_version":"4.0.9"},
       "jo":{"median_seconds":41,"samples":3,"last_seconds":44,"last_version":"1.9"},
       "zero":{"median_seconds":0,"samples":0,"last_seconds":0,"last_version":"1.0"},
       "lastonly":{"samples":1,"last_seconds":700,"last_version":"2.0"}
     }}
    """.utf8)

    @Test func decodesAndMissingIsNoData() throws {
        let t = try JSONDecoder().decode(IntelbrewBuildTimes.self, from: Self.fixture)
        #expect(t.schema == 1)
        #expect(t.measuredOn == "intelbrew-builder (macOS 14, x86_64)")
        #expect(t.seconds("ruby") == 1412.4)
        #expect(t.seconds("lastonly") == 700)
        #expect(t.seconds("zero") == nil) // never zero
        #expect(t.seconds("absent") == nil)
        let c = CompileClassifier(estimator: BuildTimeTable(seconds: ["ruby": t.seconds("ruby")!]))
        let e = CatalogEntry(kind: .formula, name: "ruby", fullName: "ruby", tap: "homebrew/core", desc: nil, bottle: .fromSource)
        #expect(c.installWarning(e)?.estimateText == "at least ~24 min on the Intelbrew builder")
    }

    @Test func fetchesOnceThenCaches24Hours() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = FetchCounter([(Self.fixture, 200)])
        let clock = TestClock()
        let src = BuildTimeSource(fetch: { try counter.next() }, cacheURL: dir.appendingPathComponent("bt.json"), now: { clock.now })
        #expect(src.estimatedSeconds(forFormula: "ruby") == nil) // nothing until asked
        #expect(counter.count == 0)
        await src.refreshIfNeeded()
        #expect(counter.count == 1)
        #expect(src.estimatedSeconds(forFormula: "jo") == 41)
        clock.advance(23 * 3600)
        await src.refreshIfNeeded()
        #expect(counter.count == 1) // within 24 h
        clock.advance(2 * 3600)
        await src.refreshIfNeeded()
        #expect(counter.count == 2) // stale: asked again
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bt.json").path))
    }

    @Test func errorsAnd404KeepTheCache() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let first = BuildTimeSource(fetch: { (Self.fixture, 200) }, cacheURL: dir.appendingPathComponent("bt.json"), now: { clock.now })
        await first.refreshIfNeeded()
        // A later launch, a day on: the asset is being replaced (404), then the network is down.
        clock.advance(30 * 3600)
        let counter = FetchCounter([(Data("Not Found".utf8), 404)])
        let second = BuildTimeSource(fetch: { try counter.next() }, cacheURL: dir.appendingPathComponent("bt.json"), now: { clock.now })
        await second.refreshIfNeeded()
        #expect(counter.count == 1)
        #expect(second.estimatedSeconds(forFormula: "ruby") == 1412.4) // the cached copy
        await second.refreshIfNeeded()
        #expect(counter.count == 1) // no retry within the hour
        clock.advance(3601)
        let failing = BuildTimeSource(fetch: { throw URLError(.timedOut) }, cacheURL: dir.appendingPathComponent("bt.json"), now: { clock.now })
        await failing.refreshIfNeeded()
        #expect(failing.estimatedSeconds(forFormula: "jo") == 41)
        // Wrong schema or garbage: no data either.
        let bad = BuildTimeSource(fetch: { (Data(#"{"schema":2,"formulae":{}}"#.utf8), 200) }, cacheURL: nil, now: { clock.now })
        await bad.refreshIfNeeded()
        #expect(bad.table == nil)
    }

    @MainActor @Test func onlyIntelbrewModeFetches() async throws {
        let counter = FetchCounter([(Self.fixture, 200)])
        // Normal mode (arm64 fixture), with a source wired in anyway: never fetched.
        let client = BrewClient(installation: BrewInstallation(brewPath: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew", repository: "/opt/homebrew"),
                                platform: BottlePlatform(arch: .arm64, macOSVersion: "27", cellar: "/opt/homebrew/Cellar"),
                                runner: FakeInfoRunner(log: CallLog(), info: Demo.fixtureInfo(.arm64)),
                                sources: EnvironmentSources(process: ["HOME": "/Users/t"]), fileExists: { _ in false })
        var deps = AppStore.Dependencies(makeClient: { client }, streamRunner: FakeStreamRunner(log: CallLog()) { _, _ in 0 }, cache: nil, logURL: nil)
        let src = BuildTimeSource(fetch: { try counter.next() }, cacheURL: nil)
        deps.buildTimes = src
        deps.classifier = CompileClassifier(estimator: src)
        let normal = AppStore(deps: deps)
        await normal.start()
        normal.compileWarningShown()
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.count == 0)

        // Intelbrew mode: the first warning fetches, and the estimate reaches ruby's warning.
        var ideps = AppStore.Dependencies(makeClient: { makeClient(FakeInfoRunner(log: CallLog(), info: demoIntelInfo())) },
                                          streamRunner: FakeStreamRunner(log: CallLog()) { _, _ in 0 }, cache: nil, logURL: nil)
        ideps.buildTimes = src
        ideps.classifier = CompileClassifier(estimator: src)
        let store = AppStore(deps: ideps)
        await store.start()
        let ruby = try #require(store.packages.first { $0.name == "ruby" })
        #expect(store.deps.classifier.upgradeWarning(ruby)?.estimateText == nil)
        store.compileWarningShown()
        #expect(await waitUntil { store.buildTimesRevision > 0 })
        #expect(counter.count == 1)
        #expect(store.deps.classifier.upgradeWarning(ruby)?.text == "No bottle: will compile from source (at least ~24 min on the Intelbrew builder)")
    }
}

// MARK: review fixes

struct BuildTimesHardeningTests {
    func table(_ json: String) throws -> IntelbrewBuildTimes {
        try JSONDecoder().decode(IntelbrewBuildTimes.self, from: Data(json.utf8))
    }

    @Test func outOfRangeTimesAreNoData() throws {
        let t = try table("""
        {"schema":1,"formulae":{
          "huge":{"median_seconds":1e30},
          "huge-then-last":{"median_seconds":1e30,"last_seconds":600},
          "negative":{"median_seconds":-5,"last_seconds":-1},
          "zero":{"median_seconds":0},
          "limit":{"median_seconds":10000000},
          "fine":{"median_seconds":9999999}
        }}
        """)
        #expect(t.seconds("huge") == nil)
        #expect(t.seconds("huge-then-last") == 600)
        #expect(t.seconds("negative") == nil)
        #expect(t.seconds("zero") == nil)
        #expect(t.seconds("limit") == nil)
        #expect(t.seconds("fine") == 9_999_999)
        // JSON has no NaN or Infinity: JSONDecoder refuses them, so such a file is no data at all.
        #expect(throws: (any Error).self) { try table(#"{"schema":1,"formulae":{"x":{"median_seconds":NaN}}}"#) }
        #expect(throws: (any Error).self) { try table(#"{"schema":1,"formulae":{"x":{"median_seconds":Infinity}}}"#) }
        #expect(BuildTimeSource.decode(Data(#"{"schema":1,"formulae":{"x":{"median_seconds":NaN}}}"#.utf8)) == nil)
    }

    @Test func estimateTextNeverTraps() {
        for bad in [1e30, Double.nan, Double.infinity, -Double.infinity, -60, 0, 1e7, Double.greatestFiniteMagnitude] {
            #expect(CompileWarning(context: .install, estimatedSeconds: bad).estimateText == nil)
        }
        #expect(CompileWarning(context: .install, estimatedSeconds: 9_999_999).estimateText == "at least ~2778 h on the Intelbrew builder")
    }

    @Test func emptyTableKeepsTheCache() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("bt.json")
        let clock = TestClock()
        let good = BuildTimeSource(fetch: { (BuildTimesTests.fixture, 200) }, cacheURL: file, now: { clock.now })
        await good.refreshIfNeeded()
        let onDisk = try Data(contentsOf: file)
        clock.advance(25 * 3600)
        let empty = BuildTimeSource(fetch: { (Data(#"{"schema":1,"generated_at":"x","formulae":{}}"#.utf8), 200) },
                                    cacheURL: file, now: { clock.now })
        await empty.refreshIfNeeded()
        #expect(empty.estimatedSeconds(forFormula: "ruby") == 1412.4) // in memory
        #expect(try Data(contentsOf: file) == onDisk)                 // on disk
    }

    @Test func oversizeResponseIsRejected() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("bt.json")
        let clock = TestClock()
        await BuildTimeSource(fetch: { (BuildTimesTests.fixture, 200) }, cacheURL: file, now: { clock.now }).refreshIfNeeded()
        let onDisk = try Data(contentsOf: file)
        // A valid table padded past the 5 MB cap.
        var big = #"{"schema":1,"formulae":{"ruby":{"median_seconds":60}},"pad":""#
        big += String(repeating: "x", count: BuildTimeSource.maxBytes)
        big += #""}"#
        let payload = Data(big.utf8)
        #expect(payload.count > BuildTimeSource.maxBytes)
        clock.advance(25 * 3600)
        let src = BuildTimeSource(fetch: { (payload, 200) }, cacheURL: file, now: { clock.now })
        await src.refreshIfNeeded()
        #expect(src.estimatedSeconds(forFormula: "ruby") == 1412.4)
        #expect(try Data(contentsOf: file) == onDisk)
        #expect(BuildTimeSource.resourceTimeout == 30)
    }
}

@MainActor
struct NotificationReviewTests {
    @Test func turnedOffDuringTheCheckPostsNothing() async throws {
        let log = CallLog()
        let runner = MutableInfoRunner(log: log, info: Demo.currentInfo(.intelbrew, base: Demo.fixtureInfo(.intelbrew), upgraded: ["xz"]))
        let client = makeClient(runner)
        let settings = testSettings()
        // `brew update` is where the user switches notifications off.
        let stream = FakeStreamRunner(log: log) { args, _ in
            if args.first == "update", await MainActor.run(body: { settings.notifiedUpgrades != nil }) {
                await MainActor.run { settings.notifyNewUpgrades = false }
            }
            return 0
        }
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: stream, cache: nil, logURL: nil),
                             settings: settings)
        await store.start()
        let notifier = FakeNotifier()
        let checker = BackgroundChecker(store: store, settings: settings, notifier: notifier, launchedAt: Date().addingTimeInterval(-3600))
        settings.notifyNewUpgrades = true
        await checker.runCheck() // baseline (4 upgrades)
        #expect(settings.notifiedUpgrades?.count == 4)
        runner.info = demoIntelInfo() // a new upgrade appears…
        await checker.runCheck()      // …but notifications go off during brew update
        #expect(!settings.notifyNewUpgrades)
        #expect(notifier.posted.isEmpty)
        #expect(log.count("update") == 2)
    }

    @Test func identifierIsStableAcrossLaunches() {
        let a = UpgradeNotificationDiff.Message(title: "t", body: "b", newKeys: ["formula:homebrew/core/xz@5.8.4", "formula:homebrew/core/ruby@4.0.9"])
        let b = UpgradeNotificationDiff.Message(title: "other", body: "other", newKeys: ["formula:homebrew/core/ruby@4.0.9", "formula:homebrew/core/xz@5.8.4"])
        #expect(a.identifier == b.identifier) // same set, any order
        // SHA-256 of the sorted keys joined by newlines: fixed, not Hasher's per-launch seed.
        #expect(a.identifier == "upgrades-" + sha256Hex("formula:homebrew/core/ruby@4.0.9\nformula:homebrew/core/xz@5.8.4"))
        #expect(a.identifier.count == "upgrades-".count + 64)
        let c = UpgradeNotificationDiff.Message(title: "t", body: "b", newKeys: ["formula:homebrew/core/xz@5.8.5"])
        #expect(c.identifier != a.identifier)
    }
}

func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}
