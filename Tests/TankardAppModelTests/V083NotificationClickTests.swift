import Foundation
import Testing
@testable import TankardAppModel
@testable import TankardCore

// 0.8.3: clicking an upgrade notification opens Installed ▸ Upgrades;
// Upgrade All… opens the plan sheet and never starts brew by itself.

struct NotificationRouteTests {
    @Test func routes() {
        let defaultAction = "com.apple.UNNotificationDefaultActionIdentifier"
        #expect(NotificationRoute.route(action: defaultAction, kind: "upgrades") == .showUpgrades)
        // Posted before 0.8.3: no kind in userInfo.
        #expect(NotificationRoute.route(action: defaultAction, kind: nil) == .showUpgrades)
        #expect(NotificationRoute.route(action: defaultAction, kind: "autoUpdate") == .showAutoUpdateLog)
        #expect(NotificationRoute.route(action: NotificationRoute.upgradeAllAction, kind: "upgrades") == .upgradeAll)
        #expect(NotificationRoute.route(action: NotificationRoute.laterAction, kind: "upgrades") == .later)
        #expect(NotificationRoute.route(action: "com.apple.UNNotificationDismissActionIdentifier", kind: nil) == .later)
        #expect(!NotificationRoute.later.opensWindow)
        #expect(NotificationRoute.upgradeAll.opensWindow && NotificationRoute.showUpgrades.opensWindow)
    }

    @Test func messageKinds() {
        let m = UpgradeNotificationDiff.decide(previous: [], current: ["a@1"], packages: [])
        #expect(m?.kind == .upgrades)
        let run = AutoUpdateRun(startedAt: Date(), finishedAt: Date(), note: "Nothing to upgrade")
        #expect(run.notification?.kind == .autoUpdate)
    }
}

@MainActor
struct NotificationClickTests {
    func rig(start: Bool = true) async -> (AppStore, CallLog) {
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: log) { _, out in out(Data("ok\n".utf8)); return 0 }
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil))
        if start { await store.start() }
        return (store, log)
    }

    @Test func clickShowsTheUpgradesList() async {
        let (store, log) = await rig()
        store.tab = .discover
        store.filter = .pinned
        store.search = "zzz"
        await store.handleNotification(.showUpgrades)
        #expect(store.tab == .installed && store.filter == .upgrades && store.search.isEmpty)
        #expect(store.visiblePackages.count == store.upgradable.count + store.packages.filter { $0.upgradeAvailable && !$0.isUpgradeTarget }.count)
        #expect(!store.showUpgradeSheet && store.upgradePlan == nil)
        #expect(log.count("upgrade") == 0)
    }

    @Test func upgradeAllOpensThePlanAndRunsNothing() async throws {
        let (store, log) = await rig()
        store.filter = .source
        await store.handleNotification(.upgradeAll)
        #expect(store.filter == .upgrades)
        let plan = try #require(store.upgradePlan)
        #expect(store.showUpgradeSheet)
        #expect(plan.rows.count == store.upgradable.count)
        #expect(store.upgrade == nil)
        #expect(log.count("upgrade") == 0)
        // Cancel: still nothing ran.
        store.cancelUpgradePlan()
        #expect(log.count("upgrade") == 0)
    }

    @Test func upgradeAllPlanEvenWhenNothingCompiles() async throws {
        let (store, log) = await rig()
        store.requestUpgradeAllPlan()
        // requestUpgrade() would start at once without compiles; the
        // notification path always asks first.
        let plan = try #require(store.upgradePlan)
        #expect(!plan.rows.isEmpty)
        #expect(log.count("upgrade") == 0)
    }

    @Test func upgradeAllWhileRunningShowsTheSession() async throws {
        let (store, _) = await rig()
        store.startUpgrade()
        store.showUpgradeSheet = false
        store.requestUpgradeAllPlan()
        #expect(store.showUpgradeSheet)
        #expect(store.upgradePlan == nil)
    }

    @Test func coldLaunchWaitsForTheList() async throws {
        let (store, log) = await rig(start: false)
        #expect(store.report == nil)
        let click = Task { await store.handleNotification(.upgradeAll, timeout: .seconds(5)) }
        await store.start()
        await click.value
        #expect(store.upgradePlan != nil)
        #expect(log.count("upgrade") == 0)
    }

    @Test func laterDoesNothing() async {
        let (store, _) = await rig()
        store.filter = .pinned
        await store.handleNotification(.later)
        #expect(store.filter == .pinned)
        #expect(!store.showUpgradeSheet)
    }

    @Test func autoUpdateClickOpensTheLog() async {
        let (store, _) = await rig()
        await store.handleNotification(.showAutoUpdateLog)
        #expect(store.showAutoUpdateLog)
    }
}
