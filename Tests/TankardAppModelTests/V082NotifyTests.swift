import Foundation
import Testing
@testable import TankardAppModel
@testable import TankardCore

// 0.8.2: a Refresh / Check Now says what it found, and notifies only when
// the user can't see the window (see UserCheckFeedback.swift).

@MainActor
struct UserCheckFeedbackTests {
    @Test func decisionTable() {
        // Window in front, setting on: the list shows it, no banner.
        var f = UserCheckFeedback.decide(newUpgrades: 3, notifyOn: true, windowInFront: true, hintShown: false)
        #expect(f.note == "3 new upgrades")
        #expect(!f.post && !f.showHint)
        // Window not in front, setting on: banner.
        f = UserCheckFeedback.decide(newUpgrades: 1, notifyOn: true, windowInFront: false, hintShown: false)
        #expect(f.note == "1 new upgrade")
        #expect(f.post && !f.showHint)
        // Nothing new: no banner either way, and no hint.
        f = UserCheckFeedback.decide(newUpgrades: 0, notifyOn: true, windowInFront: false, hintShown: false)
        #expect(f.note == "No new upgrades")
        #expect(!f.post && !f.showHint)
        f = UserCheckFeedback.decide(newUpgrades: 0, notifyOn: false, windowInFront: true, hintShown: false)
        #expect(!f.post && !f.showHint)
        // Setting off: never a banner; the hint once, only where it's seen.
        f = UserCheckFeedback.decide(newUpgrades: 2, notifyOn: false, windowInFront: true, hintShown: false)
        #expect(!f.post && f.showHint)
        f = UserCheckFeedback.decide(newUpgrades: 2, notifyOn: false, windowInFront: true, hintShown: true)
        #expect(!f.showHint)
        f = UserCheckFeedback.decide(newUpgrades: 2, notifyOn: false, windowInFront: false, hintShown: false)
        #expect(!f.post && !f.showHint)
    }

    func rig(_ settings: AppSettings) async -> (AppStore, MutableInfoRunner, CallLog, FakeNotifier) {
        let log = CallLog()
        let runner = MutableInfoRunner(log: log, info: Demo.currentInfo(.intelbrew, base: Demo.fixtureInfo(.intelbrew), upgraded: ["xz"]))
        let client = makeClient(runner)
        let stream = FakeStreamRunner(log: log) { _, _ in 0 }
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: stream, cache: nil, logURL: nil),
                             settings: settings)
        await store.start()
        let notifier = FakeNotifier()
        store.notifier = notifier
        return (store, runner, log, notifier)
    }

    @Test func refreshInFrontShowsANoteAndPostsNothing() async throws {
        let settings = testSettings()
        settings.notifyNewUpgrades = true
        let (store, runner, log, notifier) = await rig(settings)
        runner.info = demoIntelInfo() // xz's upgrade appears
        await store.refreshFromUser(windowInFront: { true })
        #expect(log.count("update") == 1)
        #expect(store.checkNote == "1 new upgrade")
        #expect(notifier.posted.isEmpty)
        // Seen: the background check won't announce xz later.
        #expect(settings.notifiedUpgrades == UpgradeNotificationDiff.keys(store.packages))
        let checker = BackgroundChecker(store: store, settings: settings, notifier: notifier, launchedAt: Date().addingTimeInterval(-3600))
        await checker.runCheck()
        #expect(notifier.posted.isEmpty)
    }

    @Test func checkNowWithTheWindowAwayPosts() async throws {
        let settings = testSettings()
        settings.notifyNewUpgrades = true
        let (store, runner, _, notifier) = await rig(settings)
        runner.info = demoIntelInfo()
        await store.refreshFromUser(windowInFront: { false })
        #expect(notifier.posted.count == 1)
        #expect(notifier.posted.first?.body == "New: xz")
        // The same set again: nothing new, no second banner.
        await store.refreshFromUser(windowInFront: { false })
        #expect(notifier.posted.count == 1)
        #expect(store.checkNote == "No new upgrades")
    }

    @Test func settingOffNeverPostsAndHintsOnce() async throws {
        let settings = testSettings()
        #expect(!settings.notifyNewUpgrades) // off by default (Derek's case)
        let (store, runner, _, notifier) = await rig(settings)
        runner.info = demoIntelInfo()
        await store.refreshFromUser(windowInFront: { false })
        #expect(notifier.posted.isEmpty)
        #expect(!settings.notifyHintShown) // not in front: not seen, not spent
        #expect(settings.notifiedUpgrades == nil) // no baseline while off

        // xz goes away and comes back, window in front: the hint, once.
        let without = Demo.currentInfo(.intelbrew, base: Demo.fixtureInfo(.intelbrew), upgraded: ["xz"])
        runner.info = without
        await store.refreshFromUser(windowInFront: { true })
        #expect(store.checkNote == "No new upgrades")
        runner.info = demoIntelInfo()
        await store.refreshFromUser(windowInFront: { true })
        #expect(store.checkNote == "1 new upgrade · " + UserCheckFeedback.hint)
        #expect(settings.notifyHintShown)
        #expect(AppSettings(defaults: settings.defaults).notifyHintShown) // persisted
        runner.info = without
        await store.refreshFromUser(windowInFront: { true })
        runner.info = demoIntelInfo()
        await store.refreshFromUser(windowInFront: { true })
        #expect(store.checkNote == "1 new upgrade")
        #expect(notifier.posted.isEmpty)
    }

    @Test func failedRefreshSaysNothingNew() async throws {
        let settings = testSettings()
        settings.notifyNewUpgrades = true
        let log = CallLog()
        let runner = MutableInfoRunner(log: log, info: demoIntelInfo())
        let client = makeClient(runner)
        let stream = FakeStreamRunner(log: log) { _, _ in 1 } // brew update fails
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: stream, cache: nil, logURL: nil),
                             settings: settings)
        await store.start()
        let notifier = FakeNotifier()
        store.notifier = notifier
        await store.refreshFromUser(windowInFront: { false })
        #expect(store.error != nil)
        #expect(store.checkNote == nil)
        #expect(notifier.posted.isEmpty)
    }
}
