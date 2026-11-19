import Foundation
import TankardCore

/// 0.8.5: where the activity (the upgrade plan, the running session, the
/// App Management pages) shows. A menu-bar Upgrade used to open the whole
/// main window with the sheet on top; with the window closed or behind
/// other apps it now shows in a small progress panel of its own, centered,
/// and the main window stays as it was.
public enum ActivityPresentation: String, Sendable {
    /// The main window's sheet (every path but the menu bar's, and the
    /// menu bar's when the window is already in front).
    case mainWindowSheet
    /// The standalone progress panel (TankardApp/ProgressPanel.swift).
    case progressPanel
}

public extension AppStore {
    /// The progress panel is up.
    var showsProgressPanel: Bool { showUpgradeSheet && activityPresentation == .progressPanel }

    /// The main window's activity sheet is up.
    var showsActivitySheet: Bool { showUpgradeSheet && activityPresentation == .mainWindowSheet }

    /// The menu-bar panel's Upgrade All (`packages == nil`) and a row's
    /// Upgrade: the same path as the window's buttons (plan first when
    /// something compiles or needs the password), shown in the progress
    /// panel unless the main window is in front. Something already in
    /// the sheet (a plan, an offer) keeps it there, as before. Returns
    /// where it shows: the caller opens the main window for
    /// `.mainWindowSheet` (as 0.8.4 did), nothing for `.progressPanel`.
    @discardableResult
    func requestUpgradeFromMenuBar(_ packages: [Package]? = nil, windowInFront: Bool) -> ActivityPresentation {
        // 0.8.5 (review): the panel's plan or unread result, or the run
        // going, first; nothing new starts.
        if progressPanelHoldsActivity || isUpgrading { return showActivity(windowInFront: windowInFront) }
        // 0.8.5 (test pass M2, M4): a sheet already up in the window (a
        // plan, post-install notes, any other): the caller opens the
        // window, where it is; nothing starts behind it.
        if isSheetPresented { return .mainWindowSheet }
        guard !windowInFront else {
            requestUpgrade(packages)
            return .mainWindowSheet
        }
        activityPresentation = .progressPanel
        requestUpgrade(packages)
        // Nothing started (nothing to upgrade, brew not ready): no panel.
        if !showUpgradeSheet { activityPresentation = .mainWindowSheet }
        return activityPresentation
    }

    /// The panel's Show in Tankard: the same activity (the same session,
    /// nothing restarted) moves to the main window's sheet. The caller
    /// opens the window.
    func moveActivityToMainWindow() {
        guard showsProgressPanel else { return }
        activityPresentation = .mainWindowSheet
        runHome = .mainWindowSheet
    }

    /// The menu-bar panel's Show Upgrade Progress and the status bar's
    /// session button, while there is a session (running, or finished and
    /// not closed) or a plan: shows it again. With the main window in
    /// front, in its sheet (moved from the panel if it is there); else in
    /// the panel, unless the sheet already shows it (the caller then
    /// brings the window forward). A panel that is already open comes to
    /// the front (`progressPanelFrontRequests`): it may be behind other
    /// windows.
    @discardableResult
    func showActivity(windowInFront: Bool) -> ActivityPresentation {
        guard hasActivityToShow else { return activityPresentation }
        if windowInFront {
            activityPresentation = .mainWindowSheet
        } else if !showUpgradeSheet {
            activityPresentation = .progressPanel
        }
        if upgrade != nil { runHome = activityPresentation }
        showUpgradeSheet = true
        if activityPresentation == .progressPanel { progressPanelFrontRequests += 1 }
        return activityPresentation
    }

    /// 0.8.5 (test pass L4): the progress panel's window title, not a
    /// second "Tankard": "Upgrading 3 packages", then "Upgrade finished"
    /// or "Upgrade finished with problems" (a stop: "Upgrade stopped").
    var progressPanelTitle: String {
        let app = intelbrewMode ? "Intelbrew" : "Tankard"
        if progressPanelNotes != nil { return String(localized: "Post-install notes") }
        if appManagementPrompt != nil || appManagementResume != nil || interruptedRun != nil { return app }
        if let u = upgrade {
            guard u.action == .upgrade, u.isFinished, !u.stopRequested else { return u.title }
            return u.hasProblems || !u.finishedCleanly
                ? String(localized: "Upgrade finished with problems") : String(localized: "Upgrade finished")
        }
        if upgradePlan != nil { return String(localized: "Upgrade Plan") }
        return app
    }

    /// There is something Show Upgrade Progress can show.
    var hasActivityToShow: Bool { upgrade != nil || upgradePlan != nil }

    /// 0.8.5 (review): the menu-bar panel's line for `hasActivityToShow`:
    /// a plan waiting, a run going, or a run finished and not closed yet.
    var activityMenuTitle: String {
        if upgrade == nil, upgradePlan != nil { return String(localized: "Show Upgrade Plan") }
        if upgrade?.isFinished == true { return String(localized: "Show Upgrade Results") }
        return String(localized: "Show Upgrade Progress")
    }

    /// 0.8.5 (review): the progress panel holds the activity: it is on
    /// screen (a plan, a run, its results or notes), or it was hidden and
    /// its run has finished and not been looked at. The main window's
    /// own brew actions (Upgrade, Uninstall, Install, Replace) wait, as
    /// they did behind 0.8.4's sheet, so a second run never takes over
    /// the panel's or replaces a result nobody has seen. The status bar's
    /// session button moves it into the window instead.
    var progressPanelHoldsActivity: Bool {
        showsProgressPanel || (runHome == .progressPanel && !showUpgradeSheet && upgrade?.isFinished == true)
    }

    /// 0.8.5 (review): the main window's buttons that start brew: off
    /// while brew runs (as before) or the progress panel holds the
    /// activity.
    var windowBrewActionsBlocked: Bool { isUpgrading || progressPanelHoldsActivity }

    /// 0.8.5 (HK-47 review): the progress panel holds the activity, so a
    /// new run from anywhere else would replace it: says why (the busy
    /// notice) and returns true.
    func progressPanelBlocksNewRun() -> Bool {
        guard progressPanelHoldsActivity else { return false }
        if let note = windowBrewActionsNote { showBusyNotice(note) }
        return true
    }

    /// 0.8.5 (review): why the main window's brew buttons are off because
    /// of the progress panel, for their help; nil otherwise.
    var windowBrewActionsNote: String? {
        if showsProgressPanel { return String(localized: "The upgrade window is open. Close it, or click Show in Tankard, first.") }
        if progressPanelHoldsActivity {
            return String(localized: "Look at the last upgrade's results first: click its button at the bottom right of this window.")
        }
        return nil
    }

    /// The panel's close button and Esc: Hide while brew runs (the menu-bar
    /// panel's Show Upgrade Progress brings it back; the first time in a
    /// launch it asks, since closing doesn't stop brew), otherwise what the
    /// page's own cancel or Done does.
    func closeProgressPanel() {
        guard showsProgressPanel else { return }
        if progressPanelNotes != nil {
            showUpgradeSheet = false
        } else if isUpgrading {
            if !progressPanelHideExplained {
                progressPanelHideExplained = true
                progressPanelHideQuestion = true
                return
            }
            showUpgradeSheet = false
        } else if upgradePlan != nil {
            cancelUpgradePlan()
        } else if appManagementPrompt != nil {
            appManagementCancel()
        } else if appManagementResume != nil {
            appManagementResumeCancel()
        } else {
            closeUpgrade()
        }
    }

    /// 0.8.5 (review): the answer to "Closing this window doesn't stop
    /// the upgrade": close it (hide) or keep it open.
    func answerProgressPanelHideQuestion(close: Bool) {
        progressPanelHideQuestion = false
        if close, showsProgressPanel, isUpgrading { showUpgradeSheet = false }
    }

    /// From sessionFinished, at once. A progress-panel run (shown or
    /// hidden) that upgraded Tankard itself moves to the main window,
    /// where the relaunch question is.
    internal func progressPanelSessionFinished(_ session: UpgradeSession) {
        guard upgrade === session, runHome == .progressPanel, selfReplaced else { return }
        if showsProgressPanel { moveActivityToMainWindow() }
        runHome = .mainWindowSheet
        mainWindowRequests += 1
    }

    /// From sessionFinished, once the list is read again and the run's
    /// post-install notes are known. A progress-panel run that finished
    /// cleanly closes the panel after `progressPanelAutoClose` and posts
    /// "Tankard upgraded N packages"; with notes, the panel shows them
    /// instead (no auto-close). Anything else (a failure, a stop, a
    /// skipped step, a password step not done, an App Management page)
    /// leaves the panel up with Close. A run whose panel was hidden posts
    /// a notification either way (done, or "see the results").
    ///
    /// The notifications use macOS's own permission for Tankard, not the
    /// "new upgrades" setting: the user asked for this run. With
    /// notifications off in System Settings nothing is shown (the post
    /// fails quietly) and the rest is the same.
    internal func progressPanelRunSettled(_ session: UpgradeSession) {
        guard upgrade === session, runHome == .progressPanel, !selfReplaced else { return }
        let hidden = !showUpgradeSheet
        let clean = session.finishedCleanly && appManagementPrompt == nil && upgradePlan == nil
        let hasNotes = insights.pendingNotes != nil
        if hidden {
            if let message = clean && !hasNotes ? session.doneNotification : session.resultsNotification {
                notifier?.post(message)
            }
            // A clean hidden run without notes needs nothing more: the
            // notification says it, and the menu bar is back to Upgrade All.
            if clean && !hasNotes { closeUpgrade() }
            return
        }
        guard showsProgressPanel, clean else { return }
        if hasNotes {
            closeUpgrade() // the notes page
            return
        }
        let delay = progressPanelAutoClose
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            // Still this session in the panel, nothing new asked of the user.
            guard let self, self.upgrade === session, self.showsProgressPanel,
                  self.upgradePlan == nil, self.appManagementPrompt == nil else { return }
            if let message = session.doneNotification { self.notifier?.post(message) }
            self.closeUpgrade()
        }
    }

    /// 0.8.5 (review): the panel's notes page's Close.
    func closeProgressPanelNotes() {
        guard progressPanelNotes != nil else { return }
        showUpgradeSheet = false
    }
}

public extension UpgradeSession {
    /// 0.8.5: every step done, nothing failed, stopped, skipped or left
    /// for Terminal.
    var finishedCleanly: Bool {
        isFinished && !hasProblems && sudoCommand == nil && !items.isEmpty && items.allSatisfy { $0.state == .done }
    }

    /// 0.8.5: what a progress panel that closed itself posts: "Tankard
    /// upgraded 3 packages" and their names. nil for anything that isn't a
    /// clean upgrade.
    var doneNotification: UpgradeNotificationDiff.Message? {
        guard action == .upgrade, finishedCleanly else { return nil }
        let names = packages.map(\.name)
        let n = names.count
        let title = String(localized: "Tankard upgraded \(n) packages", bundle: L10n.bundle)
        let body = names.prefix(4).joined(separator: ", ") + (n > 4 ? String(localized: " and \(n - 4) more") : "")
        return UpgradeNotificationDiff.Message(title: title, body: body, newKeys: ["upgrade@\(id.uuidString)"], kind: .upgradeDone)
    }

    /// 0.8.5 (review): what a hidden progress-panel run posts when it
    /// isn't a clean upgrade with nothing to read: a problem, or notes.
    /// A click shows the results (`NotificationRoute.showUpgradeResults`).
    var resultsNotification: UpgradeNotificationDiff.Message? {
        guard isFinished else { return nil }
        let title = hasProblems || !finishedCleanly
            ? String(localized: "The upgrade finished with problems")
            : String(localized: "The upgrade finished")
        let body = hasProblems || !finishedCleanly
            ? String(localized: "Click to see what happened.")
            : String(localized: "Click to read the notes Homebrew printed.")
        return UpgradeNotificationDiff.Message(title: title, body: body, newKeys: ["results@\(id.uuidString)"], kind: .upgradeResults)
    }
}

/// 0.8.5 (review): whether the main window is "in front" for a menu-bar
/// Upgrade (then its sheet, else the progress panel). The app reads the
/// facts from AppKit (MainWindowState); the rule is here, testable.
public enum MainWindowFront {
    public struct Window: Sendable {
        /// The WindowGroup's window ("main-…"), not Settings, the
        /// menu-bar panel or the progress panel.
        public var isMain: Bool
        public var isVisible: Bool
        public var isMiniaturized: Bool
        /// `occlusionState.contains(.visible)`: some of it is on screen,
        /// not all covered by other apps' windows.
        public var isUnoccluded: Bool
        /// On the Space being shown.
        public var isOnActiveSpace: Bool

        public init(isMain: Bool, isVisible: Bool, isMiniaturized: Bool, isUnoccluded: Bool, isOnActiveSpace: Bool) {
            self.isMain = isMain
            self.isVisible = isVisible
            self.isMiniaturized = isMiniaturized
            self.isUnoccluded = isUnoccluded
            self.isOnActiveSpace = isOnActiveSpace
        }
    }

    /// In front: Tankard is active, the user was last in a main window
    /// (`mainWindowHadFocus`: one became key since Tankard last became
    /// active, so the click on the menu-bar item, which activates Tankard
    /// too, doesn't count by itself), and a main window is on screen: not
    /// minimized, not entirely covered, on this Space.
    public static func inFront(appActive: Bool, mainWindowHadFocus: Bool, windows: [Window]) -> Bool {
        guard appActive, mainWindowHadFocus else { return false }
        return windows.contains { $0.isMain && $0.isVisible && !$0.isMiniaturized && $0.isUnoccluded && $0.isOnActiveSpace }
    }
}

public extension AppStore {
    /// 0.8.5, demo only (TANKARD_DEMO_PANEL): the progress panel on one
    /// page, for the render check (Scripts/panel-check.sh): `plan`,
    /// `running`, `finished` (no auto-close), `failed` (with
    /// TANKARD_DEMO_FAIL naming one of the run's packages) or `notes`.
    func demoProgressPanel(_ page: String) {
        progressPanelAutoClose = .seconds(3600)
        activityPresentation = .progressPanel
        let plain = upgradable.filter { $0.kind == .formula && $0.caveats == nil }
        switch page {
        case "plan":
            requestUpgradeAllPlan()
        case "notes":
            progressPanelAutoClose = .zero
            startUpgrade(Array(upgradable.filter { $0.caveats != nil }.prefix(1)))
        default:
            startUpgrade(Array(plain.prefix(3)))
        }
        if !showUpgradeSheet { activityPresentation = .mainWindowSheet }
    }
}
