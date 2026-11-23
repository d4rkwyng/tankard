import Foundation
import TankardCore

/// 0.8.3: what a click on one of Tankard's notifications does. The app's
/// UNUserNotificationCenter delegate turns the response into a route
/// (plain strings, so this stays testable without UserNotifications) and
/// hands it to `AppStore.handleNotification(_:)` on the main actor.
public enum NotificationRoute: Equatable, Sendable {
    /// A click on an "upgrades ready" notification: the Installed tab,
    /// Upgrades filter.
    case showUpgrades
    /// Its "Upgrade All…" action: the same list, then the Upgrade All plan
    /// sheet. It never starts an upgrade by itself.
    case upgradeAll
    /// Its "Later" action: nothing (the notification just goes away).
    case later
    /// A click on an auto-update result: the Auto-update log.
    case showAutoUpdateLog
    /// 0.8.5: a click on "Tankard upgraded N packages" (a progress panel
    /// that closed itself): History, where the run's commands are.
    case showHistory
    /// 0.8.5 (review): a click on a hidden progress-panel run's "The
    /// upgrade finished…": its results, in the main window.
    case showUpgradeResults
    /// A click on "A bottle is available for vim", or its Show action:
    /// Installed ▸ Bottle available. It never starts a replace.
    case showBottleAvailable

    /// The category with the Upgrade All… and Later actions.
    public static let upgradesCategory = "net.mindtricks.tankard.upgrades"
    public static let upgradeAllAction = "net.mindtricks.tankard.upgrade-all"
    public static let laterAction = "net.mindtricks.tankard.later"
    /// The category with the Show and Later actions, for new bottles.
    public static let bottlesCategory = "net.mindtricks.tankard.bottles"
    public static let showBottlesAction = "net.mindtricks.tankard.show-bottles"
    /// userInfo key holding `UpgradeNotificationDiff.Message.Kind.rawValue`.
    public static let kindKey = "tankardKind"
    /// UNNotificationDismissActionIdentifier (only sent with
    /// `.customDismissAction`, which Tankard doesn't set; handled anyway).
    static let dismissAction = "com.apple.UNNotificationDismissActionIdentifier"

    /// `action`: the response's actionIdentifier. `kind`: the userInfo
    /// value (nil for a notification posted before 0.8.3: treated as
    /// upgrades). Anything else (the default action, a body click) opens
    /// what the notification was about.
    public static func route(action: String, kind: String?) -> NotificationRoute {
        switch action {
        case laterAction, dismissAction: return .later
        case upgradeAllAction: return .upgradeAll
        case showBottlesAction: return .showBottleAvailable
        default:
            switch kind {
            case UpgradeNotificationDiff.Message.Kind.autoUpdate.rawValue: return .showAutoUpdateLog
            case UpgradeNotificationDiff.Message.Kind.upgradeDone.rawValue: return .showHistory
            case UpgradeNotificationDiff.Message.Kind.upgradeResults.rawValue: return .showUpgradeResults
            case UpgradeNotificationDiff.Message.Kind.bottleAvailable.rawValue: return .showBottleAvailable
            default: return .showUpgrades
            }
        }
    }

    /// Whether the main window comes forward.
    public var opensWindow: Bool { self != .later }
}

extension AppStore {
    // The list itself: `showUpgrades()` (AppStore+Insights.swift, the
    // menu-bar panel's "and N more…").

    /// 0.8.3: Upgrade All from a notification: always the plan sheet first,
    /// even when nothing would compile, so a notification button never
    /// starts brew without the user seeing what will run. While an upgrade
    /// is running it shows that session instead.
    /// 0.8.6 (UI L10): the selected package in Installed, when it has an
    /// upgrade Homebrew ▸ Upgrade (⌘U) can run.
    public var selectedUpgradeTarget: Package? {
        guard tab == .installed, let id = selection, let p = packages.first(where: { $0.id == id }),
              p.isManualUpgradeTarget else { return nil }
        return p
    }

    public func requestUpgradeAllPlan() {
        if isUpgrading {
            showUpgradeSheet = true
            return
        }
        guard upgradePlan == nil, !upgradable.isEmpty else { return }
        var plan = UpgradePlan(packages: upgradable, classifier: deps.classifier)
        // 0.8.5 (newbie review H2): this plan names open apps too.
        plan.runningApps = runningCaskApps(upgradable)
        upgradePlan = plan
        showUpgradeSheet = true
    }

    /// 0.8.3: acts on a notification click. A cold launch from a
    /// notification arrives before the list is read: waits for it (at
    /// most `timeout`) before opening the plan.
    public func handleNotification(_ route: NotificationRoute, timeout: Duration = .seconds(30)) async {
        switch route {
        case .later:
            return
        case .showAutoUpdateLog:
            showAutoUpdateLog = true
        case .showHistory:
            if !isSheetPresented { openHistory() }
        case .showUpgradeResults:
            // The window comes forward (opensWindow): the run in its sheet.
            showActivity(windowInFront: true)
        case .showUpgrades:
            showUpgrades()
        case .showBottleAvailable:
            showBottleAvailable()
        case .upgradeAll:
            showUpgrades()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while report == nil || isRefreshing, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            requestUpgradeAllPlan()
        }
    }
}

/// 0.8.6 (UI L10): the Homebrew menu's Upgrade item.
public enum UpgradeMenu {
    public static func selectedTitle(_ p: Package?) -> String {
        // 0.8.8 (gauntlet 3, B10): one package is selected at a time, so
        // not "Upgrade Selected" (it read as a multi-selection command).
        p.map { String(localized: "Upgrade \($0.name)") } ?? String(localized: "Upgrade Package")
    }
}
