import Foundation
import os
import TankardCore

// 0.8.2: what a Refresh or Check Now the user asked for says when it ends.
//
// Before, a manual check said nothing about what it found, and
// notifications came only from the background check (BackgroundChecker),
// with "Notify me about new upgrades" off by default. So a Refresh that
// found new upgrades looked the same as one that found none.

/// The outcome of a check the user asked for (toolbar Refresh, ⌘R, the
/// menu bar's Check Now).
public struct UserCheckFeedback: Equatable, Sendable {
    /// The status bar's short note ("3 new upgrades", "No new upgrades").
    public var note: String
    /// Post a notification: the setting is on, upgrades are new, and the
    /// window isn't in front (with the window in front the list shows them).
    public var post: Bool
    /// Show the one-time "Turn on notifications…" hint: the setting is off,
    /// something new showed up, the window is in front and the hint wasn't
    /// shown before.
    public var showHint: Bool

    public static func decide(newUpgrades: Int, notifyOn: Bool, windowInFront: Bool, hintShown: Bool) -> UserCheckFeedback {
        let note: String
        switch newUpgrades {
        case 0: note = String(localized: "No new upgrades")
        case 1: note = String(localized: "1 new upgrade")
        default: note = String(localized: "\(newUpgrades) new upgrades")
        }
        return UserCheckFeedback(
            note: note,
            post: notifyOn && !windowInFront && newUpgrades > 0,
            showHint: !notifyOn && windowInFront && newUpgrades > 0 && !hintShown)
    }

    public static let hint = String(localized: "Turn on notifications in Settings ▸ General")
}

extension AppStore {
    static let notificationLog = Logger(subsystem: AppPaths.bundleID, category: "notifications")

    /// The Refresh button, ⌘R and Check Now: `brew update`, re-read, then
    /// say what changed. `windowInFront`: Tankard is the active app and
    /// its main window is on screen, asked when the check ends (brew update
    /// can take a while, and the user may have switched away).
    public func refreshFromUser(windowInFront: () -> Bool) async {
        let before = report == nil ? nil : UpgradeNotificationDiff.keys(packages)
        await refresh(manual: true)
        // No list before (first load) or a failed refresh (the status bar
        // says so): nothing to compare.
        guard let before, report != nil, error == nil else { return }
        let after = UpgradeNotificationDiff.keys(packages)
        let windowInFront = windowInFront()
        let feedback = UserCheckFeedback.decide(newUpgrades: after.subtracting(before).count,
                                                notifyOn: settings.notifyNewUpgrades,
                                                windowInFront: windowInFront,
                                                hintShown: settings.notifyHintShown)
        Self.notificationLog.notice("manual check: \(after.subtracting(before).count, privacy: .public) new, notify=\(self.settings.notifyNewUpgrades, privacy: .public) front=\(windowInFront, privacy: .public) post=\(feedback.post, privacy: .public)")
        if feedback.post,
           let message = UpgradeNotificationDiff.decide(previous: settings.notifiedUpgrades ?? before, current: after, packages: packages) {
            notifier?.post(message)
        }
        // The user has now seen these: a later background check won't
        // announce them again.
        if settings.notifyNewUpgrades { settings.notifiedUpgrades = after }
        if feedback.showHint { settings.notifyHintShown = true }
        showCheckNote(feedback.showHint ? feedback.note + " · " + UserCheckFeedback.hint : feedback.note,
                      seconds: feedback.showHint ? 15 : 8)
    }

    /// Shows `text` in the status bar for a few seconds.
    func showCheckNote(_ text: String, seconds: Double) {
        checkNote = text
        checkNoteToken += 1
        let token = checkNoteToken
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.checkNoteToken == token else { return }
            self.checkNote = nil
        }
    }
}
