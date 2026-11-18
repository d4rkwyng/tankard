import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.5 (owner report on 0.8.4): Upgrade All in the menu-bar panel opened
// the whole main window with the upgrade sheet on top. Now a menu-bar
// Upgrade shows in a small progress panel of its own (ProgressPanel.swift)
// unless the main window is in front; Show in Tankard moves the same run
// to the window; a clean run closes the panel by itself.

@MainActor
struct V085ProgressPanelTests {
    /// Demo data; brew's upgrade steps fail for `failing` and, while
    /// `hold` is set, wait for it.
    func rig(failing: Set<String> = [], hold: Latch? = nil, relaunch: (@MainActor @Sendable () -> Bool)? = nil,
             calls: CallLog = CallLog()) async -> AppStore {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appManagementGate = false
        deps.relaunch = relaunch
        deps.streamRunner = FakeStreamRunner(log: calls) { args, _ in
            guard args.first == "upgrade" else { return 0 }
            if let hold { await hold.wait() }
            // The qualified name ("homebrew/core/x") or the plain one.
            let fails = args.contains { a in failing.contains { a == $0 || a.hasSuffix("/" + $0) } }
            return fails ? 1 : 0
        }
        let store = AppStore(deps: deps, settings: testSettings())
        store.progressPanelAutoClose = .milliseconds(50)
        await store.start()
        return store
    }

    /// Upgrades that start at once (no plan page: a bottle, no password)
    /// and print no post-install notes (0.8.5 review: those keep the
    /// panel open on its notes page).
    func plain(_ store: AppStore, count: Int = 1) throws -> [Package] {
        let ps = store.packages.filter {
            $0.isManualUpgradeTarget && $0.kind == .formula && $0.caveats == nil
                && !UpgradePlan(packages: [$0], classifier: store.deps.classifier).needsConfirmation
        }
        try #require(ps.count >= count)
        return Array(ps.prefix(count))
    }

    @Test func menuUpgradeAllShowsTheProgressPanelNotTheWindowSheet() async throws {
        let hold = Latch()
        let store = await rig(hold: hold)
        #expect(!store.upgradable.isEmpty)
        let shown = store.requestUpgradeFromMenuBar(nil, windowInFront: false)
        #expect(shown == .progressPanel)
        #expect(store.activityPresentation == .progressPanel)
        #expect(store.showsProgressPanel)
        #expect(!store.showsActivitySheet)
        // The plan page (something compiles or asks for the password)
        // shows in the panel too, and confirming keeps the run there.
        if store.upgradePlan != nil {
            store.confirmUpgradePlan()
        }
        let session = try #require(store.upgrade)
        #expect(!session.isFinished)
        #expect(store.showsProgressPanel && !store.showsActivitySheet)
        hold.release()
        #expect(await waitUntil { session.isFinished })
    }

    @Test func aRowsUpgradeShowsThePanelTooAndTheFrontWindowKeepsTheSheet() async throws {
        let hold = Latch()
        let store = await rig(hold: hold)
        let p = try plain(store)[0]
        #expect(store.requestUpgradeFromMenuBar([p], windowInFront: false) == .progressPanel)
        let session = try #require(store.upgrade)
        #expect(session.packages.map(\.id) == [p.id])
        #expect(store.showsProgressPanel)
        hold.release()
        #expect(await waitUntil { session.isFinished })
        store.closeUpgrade()
        #expect(!store.showUpgradeSheet && store.activityPresentation == .mainWindowSheet)

        // Main window in front: today's sheet.
        let front = await rig()
        let q = try plain(front)[0]
        #expect(front.requestUpgradeFromMenuBar([q], windowInFront: true) == .mainWindowSheet)
        #expect(front.showsActivitySheet && !front.showsProgressPanel)
    }

    @Test func somethingAlreadyInTheSheetStaysThere() async throws {
        let store = await rig()
        // An earlier plan left open in the window.
        store.requestUpgradeAllPlan()
        #expect(store.showsActivitySheet)
        #expect(store.requestUpgradeFromMenuBar(nil, windowInFront: false) == .mainWindowSheet)
        #expect(store.showsActivitySheet && !store.showsProgressPanel)
    }

    @Test func nothingToUpgradeOpensNoPanel() async throws {
        let store = await rig()
        let none: [Package] = []
        #expect(store.requestUpgradeFromMenuBar(none, windowInFront: false) == .mainWindowSheet)
        #expect(!store.showUpgradeSheet && store.activityPresentation == .mainWindowSheet)
    }

    @Test func showInTankardMovesTheSameSessionWithoutASecondOne() async throws {
        let hold = Latch()
        let calls = CallLog()
        let store = await rig(hold: hold, calls: calls)
        let ps = try plain(store, count: 2)
        store.requestUpgradeFromMenuBar(ps, windowInFront: false)
        let session = try #require(store.upgrade)
        #expect(await waitUntil { session.current != nil })
        store.moveActivityToMainWindow()
        #expect(store.showsActivitySheet && !store.showsProgressPanel)
        #expect(store.upgrade === session)
        // Back to the panel (the menu-bar panel's Show Upgrade Progress,
        // window not in front), then to the window again (the status bar).
        #expect(store.showActivity(windowInFront: false) == .mainWindowSheet) // already in the sheet: stays
        store.showUpgradeSheet = false // Hide
        #expect(store.showActivity(windowInFront: false) == .progressPanel)
        #expect(store.showActivity(windowInFront: true) == .mainWindowSheet)
        #expect(store.upgrade === session)
        hold.release()
        #expect(await waitUntil { session.isFinished })
        // One brew upgrade per package: nothing ran twice.
        #expect(calls.count("upgrade") == 2)
        #expect(store.upgrade === session)
        // Moved to the window, it doesn't close by itself.
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.showsActivitySheet && store.upgrade === session)
    }

    @Test func aCleanRunClosesThePanelAndNotifies() async throws {
        let store = await rig()
        let notifier = FakeNotifier()
        store.notifier = notifier
        store.settings.notifyNewUpgrades = true
        let ps = try plain(store, count: 2)
        store.requestUpgradeFromMenuBar(ps, windowInFront: false)
        let session = try #require(store.upgrade)
        #expect(await waitUntil { session.isFinished })
        #expect(session.finishedCleanly)
        #expect(await waitUntil { !store.showUpgradeSheet })
        #expect(store.upgrade == nil)
        #expect(store.activityPresentation == .mainWindowSheet)
        let message = try #require(notifier.posted.last)
        #expect(message.kind == .upgradeDone)
        #expect(message.title == "Tankard upgraded 2 packages")
        #expect(message.body == ps.map(\.name).joined(separator: ", "))
        #expect(NotificationRoute.route(action: "com.apple.UNNotificationDefaultActionIdentifier",
                                        kind: message.kind.rawValue) == .showHistory)

        // 0.8.5 review: "notify new upgrades" off doesn't matter (macOS's
        // permission for Tankard decides; V085PanelReviewTests).
        let quiet = await rig()
        let n2 = FakeNotifier()
        quiet.notifier = n2
        quiet.requestUpgradeFromMenuBar(try plain(quiet), windowInFront: false)
        #expect(await waitUntil { quiet.upgrade == nil && !quiet.showUpgradeSheet })
        #expect(n2.posted.count == 1)
    }

    @Test func aFailedRunStaysOpen() async throws {
        // The demo's packages are fixed: pick from one store, fail in another.
        let ps = try plain(await rig(), count: 2)
        let failingStore = await rig(failing: [ps[1].name])
        let notifier = FakeNotifier()
        failingStore.notifier = notifier
        failingStore.settings.notifyNewUpgrades = true
        failingStore.requestUpgradeFromMenuBar(ps, windowInFront: false)
        let session = try #require(failingStore.upgrade)
        #expect(await waitUntil { session.isFinished })
        #expect(session.hasProblems && !session.finishedCleanly)
        try await Task.sleep(for: .milliseconds(300))
        #expect(failingStore.showsProgressPanel)
        #expect(failingStore.upgrade === session)
        #expect(notifier.posted.isEmpty)
        // Close (the panel's button, Esc, the close button).
        failingStore.closeProgressPanel()
        #expect(!failingStore.showUpgradeSheet && failingStore.upgrade == nil)
    }

    @Test func aStoppedRunStaysOpen() async throws {
        let hold = Latch()
        let store = await rig(hold: hold)
        let ps = try plain(store, count: 2)
        store.requestUpgradeFromMenuBar(ps, windowInFront: false)
        let session = try #require(store.upgrade)
        #expect(await waitUntil { session.current != nil })
        session.stopAfterCurrent()
        hold.release()
        #expect(await waitUntil { session.isFinished })
        #expect(!session.finishedCleanly)
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.showsProgressPanel)
    }

    @Test func closingWhileRunningHidesAndTheRunGoesOn() async throws {
        let hold = Latch()
        let store = await rig(hold: hold)
        store.requestUpgradeFromMenuBar(try plain(store), windowInFront: false)
        let session = try #require(store.upgrade)
        store.closeProgressPanel()
        // 0.8.5 review: the first time in a launch it asks.
        store.answerProgressPanelHideQuestion(close: true)
        #expect(!store.showUpgradeSheet)
        #expect(store.isUpgrading && store.upgrade === session)
        #expect(store.hasActivityToShow)
        // 0.8.5 review: a hidden panel run that finishes cleanly (no
        // notes) notifies and clears (V085PanelReviewTests).
        hold.release()
        #expect(await waitUntil { session.isFinished && store.upgrade == nil })
    }

    @Test func theMenuGateCountsThePanel() async throws {
        let hold = Latch()
        let store = await rig(hold: hold)
        store.requestUpgradeFromMenuBar(try plain(store), windowInFront: false)
        #expect(store.showsProgressPanel)
        #expect(store.isSheetPresented)
        #expect(store.menuActionsBlocked)
        store.closeProgressPanel() // hidden, still running
        store.answerProgressPanelHideQuestion(close: true) // asked once
        #expect(!store.isSheetPresented)
        #expect(store.menuActionsBlocked)
        let session = try #require(store.upgrade)
        hold.release()
        // 0.8.5 review: a clean hidden run clears itself (notified): no
        // sheet left for the gate.
        #expect(await waitUntil { session.isFinished && store.upgrade == nil })
        #expect(!store.isSheetPresented)
        #expect(!store.menuActionsBlocked || store.isRefreshing)
    }

    @Test func aSelfUpdateRelaunchClosesThePanel() async throws {
        let calls = CallLog()
        let ps = try plain(await rig(), count: 2)
        let failing = await rig(failing: [ps[0].name], relaunch: { calls.add(["relaunch"]); return true })
        failing.requestUpgradeFromMenuBar(ps, windowInFront: false)
        let session = try #require(failing.upgrade)
        #expect(await waitUntil { session.isFinished })
        #expect(failing.showsProgressPanel)
        failing.offerRelaunch = true
        failing.relaunchAfterSelfUpgrade()
        #expect(calls.count("relaunch") == 1)
        #expect(!failing.showUpgradeSheet && !failing.showsProgressPanel)
        #expect(failing.activityPresentation == .mainWindowSheet)
    }

    @Test func upgradingTankardItselfMovesToTheWindowForTheRelaunchQuestion() async throws {
        let store = await rig()
        let cask = AppStore.demoTankardCask(bundlePath: "/Applications/Tankard.app")
        store.activityPresentation = .progressPanel
        store.startSession(.upgrade, packages: [cask])
        #expect(store.showsProgressPanel)
        let requests = store.mainWindowRequests
        let session = try #require(store.upgrade)
        #expect(await waitUntil { session.isFinished })
        #expect(store.selfReplaced && store.offerRelaunch)
        #expect(store.showsActivitySheet && !store.showsProgressPanel)
        #expect(store.mainWindowRequests == requests + 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.upgrade === session) // not closed by itself
    }
}
