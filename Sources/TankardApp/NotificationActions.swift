import AppKit
import SwiftUI
@preconcurrency import UserNotifications
import TankardAppModel

/// 0.8.3: clicking a notification. "N upgrades ready" opens the window on
/// Installed ▸ Upgrades, and has Upgrade All… (the plan sheet, never a
/// silent upgrade) and Later. An auto-update result opens the Auto-update log.
/// "A bottle is available for vim" opens Installed ▸ Bottle available, with
/// Show and Later; it never replaces anything.
@MainActor
enum NotificationActions {
    /// Set at launch (TankardApp.init).
    static var store: AppStore?
    /// The main window's openWindow, kept from a view that has it, to open
    /// the window again after it was closed.
    static var openWindow: OpenWindowAction?

    /// The category with the two actions; registered once at launch.
    static func registerCategories(_ center: UNUserNotificationCenter) {
        let upgradeAll = UNNotificationAction(identifier: NotificationRoute.upgradeAllAction,
                                              title: String(localized: "Upgrade All…"), options: [.foreground])
        let later = UNNotificationAction(identifier: NotificationRoute.laterAction,
                                         title: String(localized: "Later"), options: [])
        let category = UNNotificationCategory(identifier: NotificationRoute.upgradesCategory,
                                              actions: [upgradeAll, later], intentIdentifiers: [], options: [])
        let showBottles = UNNotificationAction(identifier: NotificationRoute.showBottlesAction,
                                               title: String(localized: "Show"), options: [.foreground])
        let bottles = UNNotificationCategory(identifier: NotificationRoute.bottlesCategory,
                                             actions: [showBottles, later], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category, bottles])
    }

    /// Fills the content's category and kind for `message`.
    static func configure(_ content: UNMutableNotificationContent, for message: UpgradeNotificationDiff.Message) {
        content.userInfo = [NotificationRoute.kindKey: message.kind.rawValue]
        if message.kind == .upgrades { content.categoryIdentifier = NotificationRoute.upgradesCategory }
        if message.kind == .bottleAvailable { content.categoryIdentifier = NotificationRoute.bottlesCategory }
    }

    static func handle(_ route: NotificationRoute) {
        guard route.opensWindow else { return }
        showMainWindow()
        guard let store else { return }
        Task { await store.handleNotification(route) }
    }

    /// Dock icon back first (0.8.1 hide-when-closed), then the window.
    static func showMainWindow() {
        AppDelegate.dock?.prepareToShowWindow()
        NSApp.activate(ignoringOtherApps: true)
        if !bringBackMainWindow() {
            openWindow?(id: "main")
        }
    }

    /// The existing main window to the front, out of the Dock if it was
    /// minimized. false: there is none (open one). 0.8.5: also the menu
    /// bar's Open Tankard (MainWindowPick).
    @discardableResult
    static func bringBackMainWindow() -> Bool {
        let windows = NSApp.windows
        let candidates = windows.map {
            MainWindowPick.Candidate(identifier: $0.identifier?.rawValue, isVisible: $0.isVisible, isMiniaturized: $0.isMiniaturized)
        }
        guard let i = MainWindowPick.pick(candidates) else { return false }
        let w = windows[i]
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        return true
    }
}

extension NotificationPresenter {
    /// A click on a notification or one of its actions. The delegate is
    /// nonisolated and UserNotifications may call it off the main thread:
    /// copy the strings out here, then hop to the main actor. Never call
    /// @MainActor code synchronously from this callback.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let kind = response.notification.request.content.userInfo[NotificationRoute.kindKey] as? String
        let route = NotificationRoute.route(action: action, kind: kind)
        Task { @MainActor in NotificationActions.handle(route) }
        completionHandler()
    }
}

/// Keeps the window's openWindow for NotificationActions (a view modifier,
/// so ContentView needs one line).
struct NotificationWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { NotificationActions.openWindow = openWindow }
    }
}
