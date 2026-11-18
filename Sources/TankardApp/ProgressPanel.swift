import AppKit
import SwiftUI
import TankardAppModel

/// 0.8.5: the progress panel a menu-bar Upgrade opens instead of the whole
/// main window: a small titled panel, centered, with the same activity the
/// main window's sheet shows (ActivitySheet: the plan, the session, the App
/// Management pages). The store decides when it shows
/// (`AppStore.showsProgressPanel`); this only follows it.
///
/// - Level: normal. The password dialog (tankard-askpass) is a
///   `.modalPanel`-level panel of another process, so it stays above this
///   one, and Tankard, active with this panel key, can yield focus to it.
/// - Dock icon: the panel doesn't count as a window that keeps the Dock
///   icon (DockIconController.counts), so with "Hide Dock icon when the
///   window is closed" Tankard stays menu-bar-only while it shows.
/// - Not restored at launch, not in the Window menu.
@MainActor
final class ProgressPanelController: NSObject, NSWindowDelegate {
    static let identifier = "tankard-progress-panel"
    /// Set at launch (AppDelegate).
    static var shared: ProgressPanelController?

    private let store: AppStore
    private let appearance: AppearanceSettings
    private var panel: NSPanel?
    private var seenWindowRequests = 0

    init(store: AppStore, appearance: AppearanceSettings) {
        self.store = store
        self.appearance = appearance
        self.seenWindowRequests = store.mainWindowRequests
    }

    func start() {
        observe()
    }

    /// Follows the store: shows or closes the panel, and opens the main
    /// window when the store asks for it.
    private func observe() {
        let store = store
        withObservationTracking {
            _ = store.showsProgressPanel
            _ = store.mainWindowRequests
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.sync()
                    self?.observe()
                }
            }
        }
        sync()
    }

    private func sync() {
        if store.mainWindowRequests != seenWindowRequests {
            seenWindowRequests = store.mainWindowRequests
            NotificationActions.showMainWindow()
        }
        if store.showsProgressPanel { show() } else { close() }
    }

    private func show() {
        if let panel {
            if !panel.isVisible { present(panel) }
            return
        }
        let p = ProgressNSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.identifier = NSUserInterfaceItemIdentifier(Self.identifier)
        p.title = store.intelbrewMode ? "Intelbrew" : "Tankard"
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.isRestorable = false
        p.isExcludedFromWindowsMenu = true
        p.level = .normal
        p.delegate = self
        let host = NSHostingView(rootView: ProgressPanelContent(store: store, appearance: appearance))
        // The panel follows the content's size (the plan page, the session,
        // a longer App Management page).
        host.sizingOptions = [.preferredContentSize]
        p.contentView = host
        panel = p
        present(p)
    }

    private func present(_ p: NSPanel) {
        p.layoutIfNeeded()
        p.center()
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    /// Closes the panel now (the store already says it is hidden, or a
    /// relaunch is quitting). Its sheets (the Stop now? alert) go first.
    func close() {
        guard let p = panel else { return }
        while let sheet = p.attachedSheet {
            p.endSheet(sheet)
            sheet.orderOut(nil)
        }
        panel = nil
        p.delegate = nil
        p.close()
    }

    /// The close button: Hide while brew runs, otherwise the page's cancel
    /// or Close. The store's change closes the window.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        store.closeProgressPanel()
        return false
    }

    /// Show in Tankard: the same session moves to the main window's sheet.
    static func showInTankard(_ store: AppStore) {
        store.moveActivityToMainWindow()
        NotificationActions.showMainWindow()
    }
}

/// The panel's content: the activity, themed, marked as in the panel (its
/// buttons: Show in Tankard, Close).
private struct ProgressPanelContent: View {
    var store: AppStore
    var appearance: AppearanceSettings

    var body: some View {
        let theme = Theme.of(appearance.theme)
        ActivitySheet(store: store)
            .environment(\.inProgressPanel, true)
            .themed(theme)
    }
}

/// Esc does what the close button does (when no button in the content
/// takes it, such as the plan's Cancel).
private final class ProgressNSPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

private struct InProgressPanelKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 0.8.5: the activity is shown in the progress panel, not the sheet.
    var inProgressPanel: Bool {
        get { self[InProgressPanelKey.self] }
        set { self[InProgressPanelKey.self] = newValue }
    }
}
