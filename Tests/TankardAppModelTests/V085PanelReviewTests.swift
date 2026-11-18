import Foundation
import os
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

    /// HK-47 review (0.8.5): a hidden menu-bar run that failed and hasn't
    /// been read: the menus that start brew are off, and every other
    /// entry point (Clean Up, Remove Unused, Restore, Taps, Brewfile,
    /// Adopt, Turn On Apps) starts nothing and says why, so the failed
    /// result isn't replaced and its notification still opens it.
    @Test func aHiddenFailedRunBlocksEveryOtherEntryPoint() async throws {
        let ps = try base.plain(await rig(), count: 2)
        let hold = Latch()
        let store = await rig(failing: [ps[0].name], hold: hold)
        store.requestUpgradeFromMenuBar([ps[0]], windowInFront: false)
        let session = try #require(store.upgrade)
        store.closeProgressPanel()
        store.answerProgressPanelHideQuestion(close: true)
        hold.release()
        #expect(await waitUntil { session.isFinished && !store.isRefreshing })
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.progressPanelHoldsActivity && !store.showUpgradeSheet)
        let note = try #require(store.windowBrewActionsNote)
        #expect(store.menuActionsBlocked)
        // Clean Up, Remove Unused (their sheets' buttons).
        store.startCleanup()
        #expect(store.upgrade === session)
        #expect(store.busyNotice == note)
        store.openAutoremove()
        let a = try #require(store.autoremove)
        #expect(await waitUntil { a.phase == .ready })
        store.startAutoremove()
        #expect(store.upgrade === session)
        // Restore, Taps, Brewfile and Turn On Apps (an install or a tap), Adopt.
        store.startCustomSession(.restore, packages: [Package.command("brew link xz")], intelbrewMode: false,
                                 makeCommand: { _ in QueuedCommand(executable: "/usr/bin/true", arguments: [], environment: [:], display: "x") },
                                 chainKey: nil)
        #expect(store.upgrade === session)
        for action in [SessionAction.tap, .untap, .install, .adopt] {
            store.startSession(action, packages: [ps[1]])
            #expect(store.upgrade === session, "\(action)")
        }
        store.requestEnableCasks()
        store.confirmAddTap()
        try await Task.sleep(for: .milliseconds(600))
        #expect(store.upgrade === session)
        #expect(!store.startAdopt([AdoptPlanItem(token: "firefox", qualifiedName: "homebrew/cask/firefox",
                                                 appPath: "/Applications/Firefox.app", appVersion: nil,
                                                 caskVersion: "1", autoUpdates: false, policy: .automatic)]))
        #expect(store.upgrade === session && !store.showUpgradeSheet)
        // Read (the status bar's button), then closed: free again.
        store.showActivity(windowInFront: true)
        store.closeUpgrade()
        #expect(!store.menuActionsBlocked || store.isRefreshing)
        store.startCleanup()
        #expect(store.upgrade !== session && store.upgrade?.action == .cleanup)
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

// 0.8.5 test pass (results.md): H1's titles (L4), M2, M4's second half,
// and the multi-version uninstall's counts (L3).
@MainActor
struct V085TestPassTests {
    let review = V085PanelReviewTests()
    let base = V085ProgressPanelTests()

    // M2: a menu-bar row's Upgrade while a plan is up starts nothing.
    @Test func aMenuBarRowUpgradeWhileThePanelShowsAPlanStartsNothing() async throws {
        let store = await review.rig()
        let p = try base.plain(store)[0]
        store.activityPresentation = .progressPanel
        store.requestUpgradeAllPlan()
        let rows = try #require(store.upgradePlan).rows.count
        #expect(store.requestUpgradeFromMenuBar([p], windowInFront: false) == .progressPanel)
        #expect(store.upgrade == nil && store.upgradePlan?.rows.count == rows)
        #expect(store.showsProgressPanel)
        // Window in front: the same (the plan stays where it is).
        store.requestUpgradeFromMenuBar([p], windowInFront: true)
        #expect(store.upgrade == nil && store.upgradePlan?.rows.count == rows)
    }

    @Test func aMenuBarRowUpgradeWhileTheWindowShowsAPlanStartsNothing() async throws {
        let store = await review.rig()
        let p = try base.plain(store)[0]
        store.requestUpgradeAllPlan() // in the window's sheet
        #expect(store.showsActivitySheet)
        #expect(store.requestUpgradeFromMenuBar([p], windowInFront: false) == .mainWindowSheet)
        #expect(store.upgrade == nil && store.upgradePlan != nil)
        #expect(store.showsActivitySheet && !store.showsProgressPanel)
    }

    // M4, second half: the window's notes sheet up; a menu-bar Upgrade
    // opens the window on it instead of starting a run behind it.
    @Test func aMenuBarUpgradeWaitsForTheWindowsNotesSheet() async throws {
        let store = await review.rig()
        let p = try base.plain(store)[0]
        store.insights.postInstallNotes = PostInstallNotes(action: .upgrade, notes: [])
        #expect(store.isSheetPresented)
        #expect(store.requestUpgradeFromMenuBar([p], windowInFront: false) == .mainWindowSheet)
        #expect(store.upgrade == nil && !store.showUpgradeSheet)
    }

    // L4: the panel's window title follows the page.
    @Test func theProgressPanelsTitleFollowsTheRun() async throws {
        let ps = try base.plain(await review.rig(), count: 2)
        let hold = Latch()
        let store = await review.rig(failing: [ps[0].name], hold: hold)
        store.progressPanelAutoClose = .seconds(3600)
        #expect(store.progressPanelTitle == "Tankard")
        store.activityPresentation = .progressPanel
        store.requestUpgradeAllPlan()
        #expect(store.progressPanelTitle == "Upgrade Plan")
        store.cancelUpgradePlan()
        store.requestUpgradeFromMenuBar(ps, windowInFront: false)
        let session = try #require(store.upgrade)
        #expect(store.progressPanelTitle == "Upgrading 2 packages")
        hold.release()
        #expect(await waitUntil { session.isFinished })
        #expect(store.progressPanelTitle == "Upgrade finished with problems")

        let clean = await review.rig(hold: nil)
        clean.progressPanelAutoClose = .seconds(3600)
        clean.requestUpgradeFromMenuBar([ps[1]], windowInFront: false)
        let s2 = try #require(clean.upgrade)
        #expect(await waitUntil { s2.isFinished })
        #expect(clean.progressPanelTitle == "Upgrade finished")
    }

    // L3: one step per version: versions in the chips once brew says
    // which, and both counts in words.
    @Test func aMultiVersionUninstallNamesVersionsAndCountsAgree() async throws {
        var p = Package.command("probe")
        p.installedVersions = ["1.0", "1.1"]
        var dep = Package.command("probe-dep")
        dep.installedVersions = ["2.0", "2.1"]
        let removed = OSAllocatedUnfairLock(initialState: ["probe": ["1.1", "1.0"], "probe-dep": ["2.1", "2.0"]])
        let steps = AppStore.uninstallSteps([p, dep])
        let hold = Latch()
        let s = UpgradeSession(packages: steps, intelbrewMode: false, action: .uninstall,
                               queue: CommandQueue(runner: FakeStreamRunner(log: CallLog()) { args, out in
                                   await hold.wait()
                                   let name = args.last ?? ""
                                   let v = removed.withLock { $0[name]?.isEmpty == false ? $0[name]!.removeFirst() : "?" }
                                   out(Data("Uninstalling /opt/homebrew/Cellar/\(name)/\(v)... (12 files, 40KB)\n".utf8))
                                   return 0
                               }),
                               makeCommand: { p in QueuedCommand(executable: "/bin/true", arguments: [p.name], environment: [:], display: p.name) },
                               logURL: nil, onFinish: { _ in })
        #expect(s.total == 4 && s.packages.count == 2 && s.countsVersions)
        // Before brew's line: the version each step expects (L9).
        #expect(s.items.map(s.chipName) == ["probe 1.1", "probe 1.0", "probe-dep 2.1", "probe-dep 2.0"])
        hold.release()
        #expect(await waitUntil { s.isFinished })
        #expect(s.items.map(s.chipName) == ["probe 1.1", "probe 1.0", "probe-dep 2.1", "probe-dep 2.0"])
        #expect(s.countLine == "4 of 4 versions")
        #expect(s.statusLine(behindBrewUpdate: false) == "2 uninstalled (4 versions)")
    }

    @Test func removedVersionReadsBrewsLine() {
        let lines = ["==> Something", "Uninstalling /usr/local/Cellar/xz/5.8.3... (95 files, 1.9MB)"]
        #expect(UpgradeSession.removedVersion(lines, name: "xz") == "5.8.3")
        #expect(UpgradeSession.removedVersion(lines, name: "lzma") == nil)
        #expect(UpgradeSession.removedVersion(["==> Uninstalling Cask firefox"], name: "firefox") == nil)
    }

    // A single-version uninstall and an upgrade read as before.
    @Test func singleStepCountsAreUnchanged() {
        let s = UpgradeSession(packages: [Package.command("one"), Package.command("two")], intelbrewMode: false, action: .uninstall,
                               queue: CommandQueue(runner: FakeStreamRunner(log: CallLog()) { _, _ in 0 }),
                               makeCommand: { p in QueuedCommand(executable: "/bin/true", arguments: [p.name], environment: [:], display: p.name) },
                               logURL: nil, onFinish: { _ in })
        #expect(!s.countsVersions)
        #expect(s.items.map(s.chipName) == ["one", "two"])
        #expect(s.countLine == "0 of 2")
    }
}
