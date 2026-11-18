import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.5 review of the menu-bar progress panel (89d3e6f): the main window
// can't take over the panel's run, an open panel comes forward, a panel
// run's post-install notes show in the panel, the "main window in front"
// rule, closing mid-run, the menu-bar line's wording, and notifications.

@MainActor
struct V085PanelReviewTests {
    let base = V085ProgressPanelTests()

    /// The same rig as V085ProgressPanelTests, on `platform`'s demo data
    /// (only the Intelbrew demo has caveats: python@3.15).
    func rig(_ platform: Demo.Variant = .arm64, failing: Set<String> = [], hold: Latch? = nil) async -> AppStore {
        var deps = Demo.dependencies(platform, pace: 0)
        deps.appManagementGate = false
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, _ in
            guard args.first == "upgrade" else { return 0 }
            if let hold { await hold.wait() }
            let fails = args.contains { a in failing.contains { a == $0 || a.hasSuffix("/" + $0) } }
            return fails ? 1 : 0
        }
        let store = AppStore(deps: deps, settings: testSettings())
        store.progressPanelAutoClose = .milliseconds(50)
        await store.start()
        return store
    }

    /// A finished, failed run left in the panel (Close), as in the review.
    func failedRunInPanel() async throws -> (AppStore, UpgradeSession, [Package]) {
        let ps = try base.plain(await rig(), count: 2)
        let store = await rig(failing: [ps[0].name])
        store.requestUpgradeFromMenuBar([ps[0]], windowInFront: false)
        let session = try #require(store.upgrade)
        #expect(await waitUntil { session.isFinished && !store.isRefreshing })
        #expect(store.showsProgressPanel && session.hasProblems)
        return (store, session, ps)
    }

    // MARK: 1. one owner for the activity

    @Test func aFailedRunInThePanelBlocksTheWindowsBrewButtons() async throws {
        let (store, session, ps) = try await failedRunInPanel()
        #expect(store.progressPanelHoldsActivity)
        #expect(store.windowBrewActionsBlocked)
        #expect(store.windowBrewActionsNote != nil)
        // The window's Uninstall… and Upgrade can't replace the result.
        store.requestUninstall(ps[1])
        #expect(store.uninstallCandidate == nil)
        store.startUninstall(ps[1])
        store.requestUpgrade([ps[1]])
        #expect(store.upgrade === session)
        #expect(store.showsProgressPanel)
        // Close: the window is free again.
        store.closeProgressPanel()
        #expect(!store.progressPanelHoldsActivity && !store.windowBrewActionsBlocked)
        #expect(store.windowBrewActionsNote == nil)
        store.requestUninstall(ps[1])
        #expect(store.uninstallCandidate?.id == ps[1].id)
    }

    @Test func thePanelsRetryStillReplacesItsOwnResult() async throws {
        let (store, session, _) = try await failedRunInPanel()
        store.retryInSheet()
        let again = try #require(store.upgrade)
        #expect(again !== session)
        #expect(store.showsProgressPanel)
        #expect(await waitUntil { again.isFinished })
    }

    @Test func aPlanInThePanelIsntLeftStale() async throws {
        let store = await rig()
        let p = try base.plain(store)[0]
        // A plan in the panel (as a menu-bar Upgrade All that compiles).
        store.activityPresentation = .progressPanel
        store.requestUpgradeAllPlan()
        let plan = try #require(store.upgradePlan)
        #expect(store.showsProgressPanel)
        #expect(store.windowBrewActionsBlocked)
        // The window's Upgrade: refused, the plan stays and still works.
        store.requestUpgrade([p])
        #expect(store.upgrade == nil)
        #expect(store.upgradePlan?.rows.count == plan.rows.count)
        store.confirmUpgradePlan()
        let session = try #require(store.upgrade)
        #expect(store.showsProgressPanel)
        #expect(await waitUntil { session.isFinished })
    }

    @Test func aHiddenFailedRunIsShownBeforeAnythingNew() async throws {
        let ps = try base.plain(await rig(), count: 2)
        let hold = Latch()
        let store = await rig(failing: [ps[0].name], hold: hold)
        store.requestUpgradeFromMenuBar([ps[0]], windowInFront: false)
        let session = try #require(store.upgrade)
        store.closeProgressPanel()
        store.answerProgressPanelHideQuestion(close: true)
        #expect(!store.showUpgradeSheet && store.isUpgrading)
        hold.release()
        #expect(await waitUntil { session.isFinished && !store.isRefreshing })
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.upgrade === session)
        #expect(store.progressPanelHoldsActivity && store.windowBrewActionsBlocked)
        // A menu-bar row's Upgrade shows the unread result first.
        #expect(store.requestUpgradeFromMenuBar([ps[1]], windowInFront: false) == .progressPanel)
        #expect(store.upgrade === session && store.showsProgressPanel)
        // The window's status-bar button moves it there instead.
        #expect(store.showActivity(windowInFront: true) == .mainWindowSheet)
        #expect(!store.progressPanelHoldsActivity)
    }

    // MARK: 2. an open panel comes forward

    @Test func showingAnOpenPanelAsksForItToComeForward() async throws {
        let hold = Latch()
        let store = await rig(hold: hold)
        store.requestUpgradeFromMenuBar(try base.plain(store), windowInFront: false)
        #expect(store.showsProgressPanel)
        let before = store.progressPanelFrontRequests
        // Already open (perhaps behind Safari): Show Upgrade Progress.
        #expect(store.showActivity(windowInFront: false) == .progressPanel)
        #expect(store.progressPanelFrontRequests == before + 1)
        #expect(store.showActivity(windowInFront: false) == .progressPanel)
        #expect(store.progressPanelFrontRequests == before + 2)
        // Shown in the window: no panel request.
        store.showActivity(windowInFront: true)
        #expect(store.progressPanelFrontRequests == before + 2)
        hold.release()
    }

    // MARK: 3. post-install notes in the panel

    @Test func aCleanPanelRunsNotesShowInThePanelNotTheWindow() async throws {
        let store = await rig(.intelbrew)
        let notifier = FakeNotifier()
        store.notifier = notifier
        let targets = store.upgradable.filter { ["python@3.15", "sqlite"].contains($0.name) }
        try #require(targets.count == 2)
        store.activityPresentation = .progressPanel
        store.startUpgrade(targets)
        let session = try #require(store.upgrade)
        #expect(store.showsProgressPanel)
        #expect(await waitUntil { session.isFinished && session.finishedCleanly })
        // Not closed by itself: the notes page instead of the run.
        #expect(await waitUntil { store.progressPanelNotes != nil })
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.showsProgressPanel)
        #expect(store.upgrade == nil)
        #expect(store.progressPanelNotes?.notes.map(\.name) == ["python@3.15"])
        #expect(store.insights.postInstallNotes == nil && store.insights.pendingNotes == nil)
        #expect(notifier.posted.isEmpty) // the user is looking at it
        // Close: gone, nothing left for the window, the menu gate free.
        store.closeProgressPanel()
        #expect(!store.showUpgradeSheet && store.progressPanelNotes == nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(store.insights.postInstallNotes == nil)
        #expect(!store.isSheetPresented)
    }

    @Test func aHiddenRunsNotesWaitForThePanel() async throws {
        let hold = Latch()
        let store = await rig(.intelbrew, hold: hold)
        let notifier = FakeNotifier()
        store.notifier = notifier
        let targets = store.upgradable.filter { $0.name == "python@3.15" }
        try #require(targets.count == 1)
        store.activityPresentation = .progressPanel
        store.startUpgrade(targets)
        let session = try #require(store.upgrade)
        store.closeProgressPanel()
        store.answerProgressPanelHideQuestion(close: true)
        hold.release()
        #expect(await waitUntil { !notifier.posted.isEmpty })
        // Notified ("read the notes"), kept for the panel, never a sheet
        // on a window that may be closed.
        #expect(notifier.posted.last?.kind == .upgradeResults)
        #expect(store.upgrade === session)
        #expect(store.insights.postInstallNotes == nil)
        #expect(!store.isSheetPresented)
        #expect(store.activityMenuTitle == "Show Upgrade Results")
        store.showActivity(windowInFront: false)
        store.closeProgressPanel() // the run's Close
        #expect(store.showsProgressPanel && store.progressPanelNotes != nil)
        store.closeProgressPanelNotes()
        #expect(!store.showUpgradeSheet && !store.hasActivityToShow)
        try await Task.sleep(for: .milliseconds(500))
        #expect(store.insights.postInstallNotes == nil)
    }

    @Test func aRunMovedToTheWindowKeepsTheWindowsNotesSheet() async throws {
        let store = await rig(.intelbrew)
        let targets = store.upgradable.filter { $0.name == "python@3.15" }
        store.activityPresentation = .progressPanel
        store.startUpgrade(targets)
        let session = try #require(store.upgrade)
        store.moveActivityToMainWindow()
        #expect(await waitUntil { session.isFinished && !store.isRefreshing && store.insights.pendingNotes != nil })
        store.closeUpgrade()
        #expect(store.progressPanelNotes == nil)
        #expect(await waitUntil { store.insights.postInstallNotes != nil })
    }

    // MARK: 4. the main window "in front"

    @Test func mainWindowInFrontRule() {
        typealias W = MainWindowFront.Window
        let front = W(isMain: true, isVisible: true, isMiniaturized: false, isUnoccluded: true, isOnActiveSpace: true)
        #expect(MainWindowFront.inFront(appActive: true, mainWindowHadFocus: true, windows: [front]))
        // Activated only by the menu-bar click (the user was in Safari).
        #expect(!MainWindowFront.inFront(appActive: true, mainWindowHadFocus: false, windows: [front]))
        #expect(!MainWindowFront.inFront(appActive: false, mainWindowHadFocus: true, windows: [front]))
        var covered = front; covered.isUnoccluded = false
        var elsewhere = front; elsewhere.isOnActiveSpace = false
        var mini = front; mini.isMiniaturized = true
        var hidden = front; hidden.isVisible = false
        var settings = front; settings.isMain = false
        for w in [covered, elsewhere, mini, hidden, settings] {
            #expect(!MainWindowFront.inFront(appActive: true, mainWindowHadFocus: true, windows: [w]))
        }
        #expect(MainWindowFront.inFront(appActive: true, mainWindowHadFocus: true, windows: [settings, covered, front]))
        #expect(!MainWindowFront.inFront(appActive: true, mainWindowHadFocus: true, windows: []))
    }

    // MARK: 5. closing mid-run, the menu-bar line, a hidden run's end

    @Test func closingMidRunAsksOncePerLaunch() async throws {
        let hold = Latch()
        let store = await rig(hold: hold)
        let ps = try base.plain(store, count: 2)
        store.requestUpgradeFromMenuBar([ps[0]], windowInFront: false)
        let session = try #require(store.upgrade)
        #expect(store.activityMenuTitle == "Show Upgrade Progress")
        store.closeProgressPanel()
        #expect(store.progressPanelHideQuestion && store.showsProgressPanel)
        store.answerProgressPanelHideQuestion(close: false) // Keep Open
        #expect(!store.progressPanelHideQuestion && store.showsProgressPanel)
        // Asked once: the next close hides at once.
        store.closeProgressPanel()
        #expect(!store.progressPanelHideQuestion && !store.showUpgradeSheet)
        #expect(store.isUpgrading)
        store.showActivity(windowInFront: false)
        store.closeProgressPanel()
        #expect(!store.progressPanelHideQuestion && !store.showUpgradeSheet)
        hold.release()
        #expect(await waitUntil { session.isFinished })
    }

    @Test func aHiddenFailedRunNotifiesAndWaitsToBeRead() async throws {
        let ps = try base.plain(await rig(), count: 1)
        let hold = Latch()
        let store = await rig(failing: [ps[0].name], hold: hold)
        let notifier = FakeNotifier()
        store.notifier = notifier
        store.settings.notifyNewUpgrades = false
        store.requestUpgradeFromMenuBar(ps, windowInFront: false)
        let session = try #require(store.upgrade)
        store.closeProgressPanel()
        store.answerProgressPanelHideQuestion(close: true)
        hold.release()
        #expect(await waitUntil { !notifier.posted.isEmpty })
        let message = try #require(notifier.posted.last)
        #expect(message.kind == .upgradeResults)
        #expect(message.title == "The upgrade finished with problems")
        #expect(NotificationRoute.route(action: "com.apple.UNNotificationDefaultActionIdentifier",
                                        kind: message.kind.rawValue) == .showUpgradeResults)
        #expect(store.upgrade === session)
        #expect(store.hasActivityToShow)
        #expect(store.activityMenuTitle == "Show Upgrade Results")
        // The click: the results in the window's sheet.
        await store.handleNotification(.showUpgradeResults)
        #expect(store.showsActivitySheet && store.upgrade === session)
        store.closeUpgrade()
        #expect(!store.hasActivityToShow) // the menu bar: Upgrade All again
    }

    @Test func aHiddenCleanRunNotifiesAndClears() async throws {
        let hold = Latch()
        let store = await rig(hold: hold)
        let notifier = FakeNotifier()
        store.notifier = notifier
        store.settings.notifyNewUpgrades = false
        let ps = try base.plain(store, count: 2)
        store.requestUpgradeFromMenuBar(ps, windowInFront: false)
        let session = try #require(store.upgrade)
        store.closeProgressPanel()
        store.answerProgressPanelHideQuestion(close: true)
        hold.release()
        #expect(await waitUntil { session.isFinished && store.upgrade == nil })
        #expect(notifier.posted.last?.kind == .upgradeDone)
        #expect(!store.hasActivityToShow && !store.showUpgradeSheet)
    }

    @Test func theMenuLineNamesAWaitingPlan() async throws {
        let store = await rig()
        store.activityPresentation = .progressPanel
        store.requestUpgradeAllPlan()
        #expect(store.activityMenuTitle == "Show Upgrade Plan")
    }

    // MARK: 7. the done notification doesn't need "notify new upgrades"

    @Test func theDoneNotificationIgnoresTheNewUpgradesSetting() async throws {
        let store = await rig()
        let notifier = FakeNotifier()
        store.notifier = notifier
        store.settings.notifyNewUpgrades = false
        store.requestUpgradeFromMenuBar(try base.plain(store), windowInFront: false)
        #expect(await waitUntil { store.upgrade == nil && !store.showUpgradeSheet })
        #expect(notifier.posted.last?.kind == .upgradeDone)
    }
}
