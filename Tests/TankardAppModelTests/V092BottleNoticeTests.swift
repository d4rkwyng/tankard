import Foundation
import Testing
@testable import TankardAppModel
@testable import TankardCore

// A formula built from source that gains a bottle after `brew update` is
// announced once: a notification when "Notify me about new upgrades" is on
// (the same rules as new upgrades), and a banner in the window either way.
// A click opens Installed ▸ Bottle available; nothing is replaced by itself.

/// demoIntelInfo() with vim's bottle taken away: still a source build, but
/// no bottle to replace it with (so not eligible).
func vimWithoutBottle(upgraded: Set<String> = []) -> Data {
    let base = Demo.currentInfo(.intelbrew, base: Demo.fixtureInfo(.intelbrew), upgraded: upgraded)
    guard var root = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any],
          var formulae = root["formulae"] as? [[String: Any]],
          let i = formulae.firstIndex(where: { $0["name"] as? String == "vim" }) else { return base }
    formulae[i]["bottle"] = [String: Any]()
    root["formulae"] = formulae
    return (try? JSONSerialization.data(withJSONObject: root)) ?? base
}

struct BottleNoticeDiffTests {
    func source(_ name: String, version: String = "1.0") -> Package {
        var p = Package.command(name)
        p.id = "formula:homebrew/core/\(name)"
        p.name = name
        p.fullName = name
        p.status = .source
        p.installedVersion = version
        p.installedVersions = [version]
        p.currentVersion = version
        p.pouredFromBottle = false
        p.currentHasBottle = true
        p.upgradeHasBottle = nil
        return p
    }

    @Test func keysUseTheSameRulesAsReplaceWithBottle() {
        let vim = source("vim", version: "9.2")
        #expect(BottleReplacement.isEligible(vim))
        var cask = source("firefox")
        cask.kind = .cask
        cask.id = "cask:homebrew/cask/firefox"
        var poured = source("poured")
        poured.pouredFromBottle = true
        var unknown = source("unknown")
        unknown.pouredFromBottle = nil
        var pending = source("pending", version: "1.0")
        pending.upgradeAvailable = true
        pending.currentVersion = "1.1"
        var head = source("head", version: "HEAD-abc123")
        head.currentVersion = "HEAD-abc123"
        var noBottle = source("nobottle")
        noBottle.currentHasBottle = false
        noBottle.status = .noBottle
        let all = [vim, cask, poured, unknown, pending, head, noBottle]
        #expect(BottleAvailableNotificationDiff.keys(all) == ["formula:homebrew/core/vim@9.2"])
        #expect(BottleAvailableNotificationDiff.keys(all) == Set(all.filter(BottleReplacement.isEligible).map(BottleAvailableNotificationDiff.key)))
    }

    @Test func decide() throws {
        let vim = source("vim", version: "9.2")
        let ruby = source("ruby", version: "4.0")
        let now = BottleAvailableNotificationDiff.keys([vim, ruby])
        // No baseline yet: record only.
        #expect(BottleAvailableNotificationDiff.decide(previous: nil, current: now, packages: [vim, ruby]) == nil)
        // Nothing new, or a set that only shrank: nothing.
        #expect(BottleAvailableNotificationDiff.decide(previous: now, current: now, packages: [vim, ruby]) == nil)
        #expect(BottleAvailableNotificationDiff.decide(previous: now, current: ["formula:homebrew/core/vim@9.2"], packages: [vim]) == nil)
        // One new.
        let m = try #require(BottleAvailableNotificationDiff.decide(previous: ["formula:homebrew/core/ruby@4.0"], current: now, packages: [vim, ruby]))
        #expect(m.kind == .bottleAvailable)
        #expect(m.newKeys == ["formula:homebrew/core/vim@9.2"])
        #expect(m.title == "A bottle is available for vim")
        #expect(m.identifier.hasPrefix("bottles-"))
        #expect(!m.identifier.hasPrefix("upgrades-"))
        // A later version of a formula already announced is new again.
        let vim93 = source("vim", version: "9.3")
        let later = try #require(BottleAvailableNotificationDiff.decide(previous: now, current: BottleAvailableNotificationDiff.keys([vim93, ruby]), packages: [vim93, ruby]))
        #expect(later.newKeys == ["formula:homebrew/core/vim@9.3"])
        // Two, and many.
        let two = try #require(BottleAvailableNotificationDiff.decide(previous: [], current: now, packages: [vim, ruby]))
        #expect(two.title == "Bottles are available for ruby, vim")
        let many = ["a", "b", "c", "d", "e"].map { source($0) }
        let five = try #require(BottleAvailableNotificationDiff.decide(previous: [], current: BottleAvailableNotificationDiff.keys(many), packages: many))
        #expect(five.title == "5 formulae you built from source now have a bottle")
        #expect(five.body.contains("a, b, c, d and 1 more"))
    }

    @Test func feedbackNotesAndPosting() {
        // The upgrades-only table is unchanged (UserCheckFeedbackTests).
        var f = UserCheckFeedback.decide(newUpgrades: 0, newBottles: ["vim"], notifyOn: true, windowInFront: true, hintShown: false)
        #expect(f.note == "A bottle is available for vim")
        #expect(!f.post && !f.postBottles && !f.showHint)
        f = UserCheckFeedback.decide(newUpgrades: 2, newBottles: ["vim", "ruby"], notifyOn: true, windowInFront: false, hintShown: false)
        #expect(f.note == "2 new upgrades · Bottles are available for vim, ruby")
        #expect(f.post && f.postBottles)
        f = UserCheckFeedback.decide(newUpgrades: 0, newBottles: ["vim"], notifyOn: true, windowInFront: false, hintShown: false)
        #expect(!f.post && f.postBottles)
        // Setting off: never posts; bottles alone are enough for the hint.
        f = UserCheckFeedback.decide(newUpgrades: 0, newBottles: ["vim"], notifyOn: false, windowInFront: true, hintShown: false)
        #expect(!f.post && !f.postBottles && f.showHint)
        f = UserCheckFeedback.decide(newUpgrades: 0, newBottles: ["vim"], notifyOn: false, windowInFront: false, hintShown: false)
        #expect(!f.postBottles && !f.showHint)
        f = UserCheckFeedback.decide(newUpgrades: 0, newBottles: [], notifyOn: true, windowInFront: false, hintShown: false)
        #expect(f.note == "No new upgrades" && !f.postBottles)
    }

    @Test func routes() {
        let defaultAction = "com.apple.UNNotificationDefaultActionIdentifier"
        let kind = UpgradeNotificationDiff.Message.Kind.bottleAvailable.rawValue
        #expect(NotificationRoute.route(action: defaultAction, kind: kind) == .showBottleAvailable)
        #expect(NotificationRoute.route(action: NotificationRoute.showBottlesAction, kind: kind) == .showBottleAvailable)
        #expect(NotificationRoute.route(action: NotificationRoute.laterAction, kind: kind) == .later)
        #expect(NotificationRoute.route(action: "com.apple.UNNotificationDismissActionIdentifier", kind: kind) == .later)
        #expect(NotificationRoute.showBottleAvailable.opensWindow)
    }
}

@MainActor
struct BottleNoticeStoreTests {
    /// vim is a source build with no bottle; `runner.info = demoIntelInfo()`
    /// gives the same version a bottle.
    func rig(_ settings: AppSettings, info: Data = vimWithoutBottle(),
             stream: @escaping @Sendable ([String], @escaping @Sendable (Data) -> Void) async throws -> Int32 = { _, _ in 0 })
        async -> (AppStore, MutableInfoRunner, CallLog, FakeNotifier) {
        let log = CallLog()
        let runner = MutableInfoRunner(log: log, info: info)
        let client = makeClient(runner)
        let streamRunner = FakeStreamRunner(log: log, behaviour: stream)
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: streamRunner, cache: nil, logURL: nil),
                             settings: settings)
        await store.start()
        let notifier = FakeNotifier()
        store.notifier = notifier
        return (store, runner, log, notifier)
    }

    @Test func fixtureStartsWithoutAndGainsABottle() async {
        let (store, runner, _, _) = await rig(testSettings())
        #expect(store.bottleReplaceable.isEmpty)
        #expect(store.bottleNoticePackages.isEmpty)
        runner.info = demoIntelInfo()
        await store.refresh(manual: true)
        #expect(store.bottleReplaceable.map(\.name) == ["vim"])
        // A plain refresh (no comparison) announces nothing.
        #expect(store.bottleNotice == nil)
    }

    @Test func inFrontShowsTheBannerAndNoteAndPostsNothing() async {
        let settings = testSettings()
        settings.notifyNewUpgrades = true
        let (store, runner, log, notifier) = await rig(settings)
        runner.info = demoIntelInfo()
        await store.refreshFromUser(windowInFront: { true })
        #expect(log.count("update") == 1)
        #expect(store.checkNote == "A bottle is available for vim")
        #expect(store.bottleNoticePackages.map(\.name) == ["vim"])
        #expect(store.bottleNoticeText == "A bottle is available for vim")
        #expect(notifier.posted.isEmpty)
        #expect(settings.notifiedBottles?.contains("formula:homebrew/core/vim@9.2.1355") == true)
        // Seen: the background check won't announce vim later.
        let checker = BackgroundChecker(store: store, settings: settings, notifier: notifier, launchedAt: Date().addingTimeInterval(-3600))
        await checker.runCheck()
        #expect(notifier.posted.isEmpty)
        #expect(log.count("reinstall") == 0)
    }

    @Test func windowAwayPostsOnce() async throws {
        let settings = testSettings()
        settings.notifyNewUpgrades = true
        let (store, runner, log, notifier) = await rig(settings)
        runner.info = demoIntelInfo()
        await store.refreshFromUser(windowInFront: { false })
        #expect(notifier.posted.count == 1)
        let m = try #require(notifier.posted.first)
        #expect(m.kind == .bottleAvailable)
        #expect(m.title == "A bottle is available for vim")
        #expect(m.newKeys == ["formula:homebrew/core/vim@9.2.1355"])
        // The same set again: nothing new.
        await store.refreshFromUser(windowInFront: { false })
        #expect(notifier.posted.count == 1)
        #expect(store.checkNote == "No new upgrades")
        #expect(log.count("reinstall") == 0)
        #expect(store.upgrade == nil)
    }

    @Test func upgradesAndBottlesTogetherPostTwo() async throws {
        let settings = testSettings()
        settings.notifyNewUpgrades = true
        let (store, runner, _, notifier) = await rig(settings, info: vimWithoutBottle(upgraded: ["xz"]))
        runner.info = demoIntelInfo() // xz's upgrade and vim's bottle appear
        await store.refreshFromUser(windowInFront: { false })
        #expect(store.checkNote == "1 new upgrade · A bottle is available for vim")
        #expect(notifier.posted.map(\.kind) == [.upgrades, .bottleAvailable])
        #expect(notifier.posted[0].identifier != notifier.posted[1].identifier)
    }

    @Test func settingOffStillShowsTheBannerOnce() async {
        let settings = testSettings()
        #expect(!settings.notifyNewUpgrades)
        let (store, runner, _, notifier) = await rig(settings)
        runner.info = demoIntelInfo()
        await store.refreshFromUser(windowInFront: { true })
        #expect(notifier.posted.isEmpty)
        #expect(store.bottleNoticePackages.map(\.name) == ["vim"])
        #expect(store.checkNote == "A bottle is available for vim · " + UserCheckFeedback.hint)
        #expect(settings.notifyHintShown)
        // Recorded even with notifications off.
        #expect(AppSettings(defaults: settings.defaults).notifiedBottles?.contains("formula:homebrew/core/vim@9.2.1355") == true)
        store.dismissBottleNotice()
        #expect(store.bottleNotice == nil)
        // The next refresh, same vim: not again.
        await store.refreshFromUser(windowInFront: { true })
        #expect(store.bottleNotice == nil)
        #expect(store.checkNote == "No new upgrades")
        // vim's bottle goes away and comes back at the same version: still seen.
        runner.info = vimWithoutBottle()
        await store.refreshFromUser(windowInFront: { true })
        runner.info = demoIntelInfo()
        await store.refreshFromUser(windowInFront: { true })
        #expect(store.bottleNotice == nil)
        #expect(notifier.posted.isEmpty)
    }

    @Test func alreadyEligibleBeforeTheUpdateIsNotAnnounced() async {
        // First launch with this feature: vim already had a bottle.
        let settings = testSettings()
        settings.notifyNewUpgrades = true
        let (store, _, _, notifier) = await rig(settings, info: demoIntelInfo())
        #expect(settings.notifiedBottles == nil)
        await store.refreshFromUser(windowInFront: { false })
        #expect(store.bottleNotice == nil)
        #expect(notifier.posted.isEmpty)
        #expect(settings.notifiedBottles == ["formula:homebrew/core/vim@9.2.1355"])
    }

    @Test func failedRefreshKeepsTheBaseline() async {
        let settings = testSettings()
        settings.notifyNewUpgrades = true
        settings.notifiedBottles = ["formula:homebrew/core/old@1"]
        let (store, runner, _, notifier) = await rig(settings, stream: { _, _ in 1 }) // brew update fails
        runner.info = demoIntelInfo()
        await store.refreshFromUser(windowInFront: { false })
        #expect(store.error != nil)
        #expect(store.checkNote == nil)
        #expect(store.bottleNotice == nil)
        #expect(notifier.posted.isEmpty)
        #expect(settings.notifiedBottles == ["formula:homebrew/core/old@1"])
    }

    @Test func clickOpensBottleAvailableAndReplacesNothing() async {
        let (store, _, log, _) = await rig(testSettings(), info: demoIntelInfo())
        store.tab = .discover
        store.filter = .pinned
        store.search = "zzz"
        await store.handleNotification(.showBottleAvailable)
        #expect(store.tab == .installed && store.filter == .bottleAvailable && store.search.isEmpty)
        #expect(store.visiblePackages.map(\.name) == ["vim"])
        #expect(store.upgrade == nil)
        #expect(!store.showUpgradeSheet)
        #expect(log.count("reinstall") == 0)
    }

    @Test func bannerReplaceRunsOnlyTheNewOnesAndClears() async throws {
        let settings = testSettings()
        let (store, runner, log, _) = await rig(settings)
        runner.info = demoIntelInfo()
        await store.refreshFromUser(windowInFront: { true })
        #expect(store.bottleNoticePackages.map(\.name) == ["vim"])
        #expect(log.count("reinstall") == 0) // nothing yet: only the user's click starts it
        store.replaceNoticedBottles()
        let session = try #require(store.upgrade)
        #expect(session.action == .replaceBottle)
        #expect(session.items.map(\.package.name) == ["vim"])
        #expect(store.bottleNotice == nil)
        #expect(await waitUntil { session.isFinished })
        #expect(log.calls.contains(["reinstall", "--force-bottle", "--formula", "homebrew/core/vim"]))
    }

    @Test func noLongerEligibleClearsTheBanner() async {
        let (store, runner, _, _) = await rig(testSettings())
        runner.info = demoIntelInfo()
        await store.refreshFromUser(windowInFront: { true })
        #expect(store.bottleNoticeText != nil)
        runner.info = vimWithoutBottle()
        await store.refreshFromUser(windowInFront: { true })
        #expect(store.bottleNoticePackages.isEmpty)
        #expect(store.bottleNoticeText == nil)
    }

    @Test func backgroundCheckPostsOnce() async throws {
        let settings = testSettings()
        settings.notifyNewUpgrades = true
        let (store, runner, log, notifier) = await rig(settings)
        let checker = BackgroundChecker(store: store, settings: settings, notifier: notifier, launchedAt: Date().addingTimeInterval(-3600))
        await checker.runCheck() // the first check after turning it on: baseline only
        #expect(notifier.posted.isEmpty)
        runner.info = demoIntelInfo()
        await checker.runCheck()
        #expect(notifier.posted.count == 1)
        #expect(notifier.posted.first?.kind == .bottleAvailable)
        #expect(store.bottleNoticePackages.map(\.name) == ["vim"])
        await checker.runCheck()
        #expect(notifier.posted.count == 1)
        #expect(log.count("reinstall") == 0)
    }

    @Test func backgroundCheckFirstAfterTurningOnPostsNothing() async {
        let settings = testSettings()
        settings.notifyNewUpgrades = true
        let (store, runner, _, notifier) = await rig(settings)
        settings.notifiedBottles = ["x"]
        settings.notifyNewUpgrades = false
        settings.notifyNewUpgrades = true // turned on again: a fresh baseline
        #expect(settings.notifiedBottles == nil)
        runner.info = demoIntelInfo()
        let checker = BackgroundChecker(store: store, settings: settings, notifier: notifier, launchedAt: Date().addingTimeInterval(-3600))
        await checker.runCheck()
        #expect(notifier.posted.isEmpty)
        // The window still says so (compared with the list before the update).
        #expect(store.bottleNoticePackages.map(\.name) == ["vim"])
    }

    @Test func failedBackgroundCheckKeepsTheBaseline() async {
        let settings = testSettings()
        settings.notifyNewUpgrades = true
        let (store, runner, _, notifier) = await rig(settings, stream: { _, _ in 1 })
        settings.notifiedBottles = ["formula:homebrew/core/old@1"]
        runner.info = demoIntelInfo()
        let checker = BackgroundChecker(store: store, settings: settings, notifier: notifier, launchedAt: Date().addingTimeInterval(-3600))
        await checker.runCheck()
        #expect(notifier.posted.isEmpty)
        #expect(store.bottleNotice == nil)
        #expect(settings.notifiedBottles == ["formula:homebrew/core/old@1"])
    }
}

@MainActor
struct BottleNoticeBackgroundUpdateTests {
    let base = ParallelLoadTests()

    /// The throttled background `brew update` (on by default, notifications
    /// off): the banner, no notification.
    @Test func backgroundUpdateShowsTheBannerWithNotificationsOff() async throws {
        let r = try await base.rig(info: vimWithoutBottle(), backgroundUpdates: true)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        let notifier = FakeNotifier()
        let checker = BackgroundChecker(store: r.store, settings: r.settings, notifier: notifier, launchedAt: Date().addingTimeInterval(-60))
        r.runner.info = demoIntelInfo()
        await checker.tick()
        #expect(r.stream.count("update") == 1)
        #expect(r.store.bottleNoticePackages.map(\.name) == ["vim"])
        #expect(notifier.posted.isEmpty)
        #expect(r.stream.count("reinstall") == 0)
    }
}

extension BottleNoticeBackgroundUpdateTests {
    /// The same tick with notifications on and no baseline yet: the first
    /// comparison only records, but the window still names vim.
    @Test func backgroundUpdateWithNotificationsOnAndNoBaselinePostsNothing() async throws {
        let r = try await base.rig(info: vimWithoutBottle(), backgroundUpdates: true)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        r.settings.notifyNewUpgrades = true
        #expect(r.settings.notifiedBottles == nil)
        #expect(!r.store.autoUpdate.settings.enabled)
        let notifier = FakeNotifier()
        let checker = BackgroundChecker(store: r.store, settings: r.settings, notifier: notifier, launchedAt: Date().addingTimeInterval(-60))
        r.runner.info = demoIntelInfo()
        await checker.tick()
        #expect(r.stream.count("update") == 1)
        #expect(notifier.posted.isEmpty)
        #expect(r.store.bottleNoticePackages.map(\.name) == ["vim"])
        #expect(r.settings.notifiedBottles?.contains("formula:homebrew/core/vim@9.2.1355") == true)
        // Recorded: a later check doesn't announce vim.
        await checker.runCheck()
        #expect(notifier.posted.isEmpty)
        #expect(r.stream.count("reinstall") == 0)
    }
}

private let autoUpdateOfflineOutput = "fatal: unable to access 'https://github.com/Homebrew/brew/': Could not resolve host: github.com\n"

/// Auto-update's `brew update` goes through the same bottle comparison as
/// Refresh and the background check.
@MainActor
struct BottleNoticeAutoUpdateTests {
    let base = BottleNoticeStoreTests()

    func bottleMessages(_ n: FakeNotifier) -> [UpgradeNotificationDiff.Message] {
        n.posted.filter { $0.kind == .bottleAvailable }
    }

    @Test func autoUpdatePostsOnceWithABaseline() async throws {
        let settings = testSettings()
        settings.notifyNewUpgrades = true
        let (store, runner, log, notifier) = await base.rig(settings)
        settings.notifiedBottles = []
        store.autoUpdate.settings.enabled = true
        runner.info = demoIntelInfo()
        _ = try #require(await store.autoUpdate.run(store: store, notifier: notifier))
        #expect(log.count("update") == 1)
        #expect(store.bottleNoticePackages.map(\.name) == ["vim"])
        let posted = bottleMessages(notifier)
        #expect(posted.count == 1)
        #expect(posted.first?.newKeys == ["formula:homebrew/core/vim@9.2.1355"])
        #expect(log.count("reinstall") == 0)
        // A second run, then a background check: not again.
        store.dismissBottleNotice()
        _ = await store.autoUpdate.run(store: store, notifier: notifier)
        let checker = BackgroundChecker(store: store, settings: settings, notifier: notifier, launchedAt: Date().addingTimeInterval(-3600))
        await checker.runCheck()
        #expect(bottleMessages(notifier).count == 1)
        #expect(store.bottleNotice == nil)
        #expect(log.count("reinstall") == 0)
    }

    @Test func autoUpdateWithNotificationsOffShowsTheBannerOnly() async throws {
        let settings = testSettings()
        #expect(!settings.notifyNewUpgrades)
        let (store, runner, log, notifier) = await base.rig(settings)
        store.autoUpdate.settings.enabled = true
        runner.info = demoIntelInfo()
        _ = try #require(await store.autoUpdate.run(store: store, notifier: notifier))
        #expect(store.bottleNoticePackages.map(\.name) == ["vim"])
        #expect(bottleMessages(notifier).isEmpty)
        #expect(settings.notifiedBottles?.contains("formula:homebrew/core/vim@9.2.1355") == true)
        // Turning notifications on later doesn't announce vim.
        settings.notifyNewUpgrades = true
        settings.notifiedBottles = ["formula:homebrew/core/vim@9.2.1355"]
        store.autoUpdate.settings.enabled = false
        let checker = BackgroundChecker(store: store, settings: settings, notifier: notifier, launchedAt: Date().addingTimeInterval(-3600))
        await checker.runCheck()
        await checker.tick()
        #expect(bottleMessages(notifier).isEmpty)
        #expect(log.count("reinstall") == 0)
    }

    @Test func autoUpdateWithoutABaselinePostsNothing() async throws {
        let settings = testSettings()
        settings.notifyNewUpgrades = true
        let (store, runner, log, notifier) = await base.rig(settings)
        #expect(settings.notifiedBottles == nil)
        store.autoUpdate.settings.enabled = true
        runner.info = demoIntelInfo()
        _ = try #require(await store.autoUpdate.run(store: store, notifier: notifier))
        #expect(bottleMessages(notifier).isEmpty)
        #expect(store.bottleNoticePackages.map(\.name) == ["vim"])
        #expect(settings.notifiedBottles?.contains("formula:homebrew/core/vim@9.2.1355") == true)
        #expect(log.count("reinstall") == 0)
    }

    @Test func autoUpdateWithNothingToUpgradeStillCompares() async throws {
        let settings = testSettings()
        settings.notifyNewUpgrades = true
        let (store, runner, log, notifier) = await base.rig(settings)
        settings.notifiedBottles = []
        store.autoUpdate.settings.enabled = true
        store.autoUpdate.settings.defaults.set(["nothing-by-this-name"], forKey: "autoUpdateOnly")
        runner.info = demoIntelInfo()
        let run = try #require(await store.autoUpdate.run(store: store, notifier: notifier))
        #expect(run.upgraded.isEmpty && run.failed.isEmpty)
        #expect(log.count("upgrade") == 0)
        #expect(store.bottleNoticePackages.map(\.name) == ["vim"])
        #expect(bottleMessages(notifier).count == 1)
    }

    @Test func failedAutoUpdateKeepsTheBaseline() async throws {
        let settings = testSettings()
        settings.notifyNewUpgrades = true
        let (store, runner, _, notifier) = await base.rig(settings, stream: { args, _ in args.first == "update" ? 1 : 0 })
        settings.notifiedBottles = ["formula:homebrew/core/old@1"]
        store.autoUpdate.settings.enabled = true
        runner.info = demoIntelInfo()
        _ = try #require(await store.autoUpdate.run(store: store, notifier: notifier))
        #expect(store.error != nil)
        #expect(store.bottleNotice == nil)
        #expect(bottleMessages(notifier).isEmpty)
        #expect(settings.notifiedBottles == ["formula:homebrew/core/old@1"])
    }

    @Test func quietAutoUpdateKeepsTheBaseline() async throws {
        let settings = testSettings()
        settings.notifyNewUpgrades = true
        let (store, runner, _, notifier) = await base.rig(settings, stream: { args, out in
            out(Data(autoUpdateOfflineOutput.utf8))
            return args.first == "update" ? 1 : 0
        })
        settings.notifiedBottles = ["formula:homebrew/core/old@1"]
        store.autoUpdate.settings.enabled = true
        runner.info = demoIntelInfo()
        _ = try #require(await store.autoUpdate.run(store: store, notifier: notifier))
        #expect(store.lastScheduledUpdate?.quiet == .offline)
        #expect(store.bottleNotice == nil)
        #expect(bottleMessages(notifier).isEmpty)
        #expect(settings.notifiedBottles == ["formula:homebrew/core/old@1"])
    }

    @Test func dryRunComparesNothing() async throws {
        let settings = testSettings()
        settings.notifyNewUpgrades = true
        let (store, runner, log, notifier) = await base.rig(settings)
        settings.notifiedBottles = ["formula:homebrew/core/old@1"]
        store.autoUpdate.settings.enabled = true
        store.autoUpdate.settings.dryRun = true
        runner.info = demoIntelInfo()
        _ = try #require(await store.autoUpdate.run(store: store, notifier: notifier))
        #expect(log.count("update") == 0)
        #expect(store.bottleNotice == nil)
        #expect(settings.notifiedBottles == ["formula:homebrew/core/old@1"])
    }
}

@MainActor
struct BottleNoticeDemoTests {
    /// TANKARD_DEMO_BOTTLE_NOTICE: Intelbrew's vim (already eligible) as
    /// newly having a bottle; nothing replaced.
    @Test func demoSeedsTheBannerForWhatIsEligible() async {
        let (store, _, log, _) = await BottleNoticeStoreTests().rig(testSettings(), info: demoIntelInfo())
        #expect(store.bottleNoticeText == nil)
        store.demoBottleNotice()
        #expect(store.bottleNoticeText == "A bottle is available for vim")
        #expect(log.count("reinstall") == 0)
    }
}
