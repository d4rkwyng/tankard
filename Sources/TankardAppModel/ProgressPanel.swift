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
        guard !windowInFront, !showUpgradeSheet, !isUpgrading else {
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
    }

    /// The menu-bar panel's Show Upgrade Progress and the status bar's
    /// session button, while there is a session (running, or finished and
    /// not closed) or a plan: shows it again. With the main window in
    /// front, in its sheet (moved from the panel if it is there); else in
    /// the panel, unless the sheet already shows it (the caller then
    /// brings the window forward).
    @discardableResult
    func showActivity(windowInFront: Bool) -> ActivityPresentation {
        guard hasActivityToShow else { return activityPresentation }
        if windowInFront {
            activityPresentation = .mainWindowSheet
        } else if !showUpgradeSheet {
            activityPresentation = .progressPanel
        }
        showUpgradeSheet = true
        return activityPresentation
    }

    /// There is something Show Upgrade Progress can show.
    var hasActivityToShow: Bool { upgrade != nil || upgradePlan != nil }

    /// The panel's close button and Esc: Hide while brew runs (the menu-bar
    /// panel's Show Upgrade Progress brings it back), otherwise what the
    /// page's own cancel or Done does.
    func closeProgressPanel() {
        guard showsProgressPanel else { return }
        if isUpgrading {
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

    /// From sessionFinished. A progress-panel run that finished cleanly
    /// closes the panel after `progressPanelAutoClose` and posts a
    /// notification; anything else (a failure, a stop, a skipped step, a
    /// password step not done, an App Management page) leaves the panel
    /// up with Close. A run that upgraded Tankard itself moves to the main
    /// window, where the relaunch question is.
    internal func progressPanelSessionFinished(_ session: UpgradeSession) {
        guard showsProgressPanel, upgrade === session else { return }
        if selfReplaced {
            moveActivityToMainWindow()
            mainWindowRequests += 1
            return
        }
        guard session.finishedCleanly, appManagementPrompt == nil else { return }
        let delay = progressPanelAutoClose
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            // Still this session in the panel, nothing new asked of the user.
            guard let self, self.upgrade === session, self.showsProgressPanel,
                  self.upgradePlan == nil, self.appManagementPrompt == nil else { return }
            if let message = session.doneNotification, self.settings.notifyNewUpgrades { self.notifier?.post(message) }
            self.closeUpgrade()
        }
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
        let title = n == 1 ? String(localized: "Tankard upgraded \(n) package") : String(localized: "Tankard upgraded \(n) packages")
        let body = names.prefix(4).joined(separator: ", ") + (n > 4 ? String(localized: " and \(n - 4) more") : "")
        return UpgradeNotificationDiff.Message(title: title, body: body, newKeys: ["upgrade@\(id.uuidString)"], kind: .upgradeDone)
    }
}
