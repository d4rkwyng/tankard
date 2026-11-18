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
    private var seenFrontRequests = 0
    /// 0.8.5 review: where the user left the panel, for this launch (the
    /// next show puts it back there instead of re-centering).
    private var lastFrame: NSRect?

    init(store: AppStore, appearance: AppearanceSettings) {
        self.store = store
        self.appearance = appearance
        self.seenWindowRequests = store.mainWindowRequests
        self.seenFrontRequests = store.progressPanelFrontRequests
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
            _ = store.progressPanelFrontRequests
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
        // 0.8.5 review: Show Upgrade Progress on a panel that is already
        // open (maybe behind other apps' windows) brings it forward.
        let front = store.progressPanelFrontRequests != seenFrontRequests
        seenFrontRequests = store.progressPanelFrontRequests
        if store.showsProgressPanel { show(front: front) } else { close() }
    }

    private func show(front: Bool) {
        if let panel {
            if !panel.isVisible || front { present(panel) }
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
        // 0.8.5 review: shows on the Space the user is on (also over a
        // full-screen app) rather than switching Spaces to where it was.
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.delegate = self
        let host = NSHostingView(rootView: ProgressPanelContent(store: store, appearance: appearance))
        // The panel follows the content's size (the plan page, the session,
        // a longer App Management page).
        host.sizingOptions = [.preferredContentSize]
        p.contentView = host
        panel = p
        present(p)
    }

    /// Brings the panel in front of every app's windows and makes it key.
    /// Placed only when it isn't on screen yet: where the user left it
    /// this launch, else centered on the screen with the mouse (the one
    /// whose menu bar was clicked).
    private func present(_ p: NSPanel) {
        if !p.isVisible { place(p) }
        NSApp.activate(ignoringOtherApps: true)
        p.orderFrontRegardless()
        p.makeKey()
    }

    private func place(_ p: NSPanel) {
        // The content's size first, so centering uses the real one.
        p.layoutIfNeeded()
        if let size = p.contentView?.fittingSize, size.width > 0, size.height > 0 { p.setContentSize(size) }
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        var frame = p.frame
        if let last = lastFrame {
            // Same top-left corner (the height follows the page), kept on
            // a screen that still exists.
            frame.origin = NSPoint(x: last.minX, y: last.maxY - frame.height)
            let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? mouseScreen
            if let visible = screen?.visibleFrame { frame = Self.clamp(frame, to: visible) }
        } else if let visible = mouseScreen?.visibleFrame {
            frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
            frame = Self.clamp(frame, to: visible)
        } else {
            p.center()
            return
        }
        p.setFrame(frame, display: false)
    }

    private static func clamp(_ f: NSRect, to visible: NSRect) -> NSRect {
        var r = f
        r.origin.x = min(max(r.minX, visible.minX), max(visible.minX, visible.maxX - r.width))
        r.origin.y = min(max(r.minY, visible.minY), max(visible.minY, visible.maxY - r.height))
        return r
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
        if p.isVisible { lastFrame = p.frame }
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
    @Bindable var store: AppStore
    var appearance: AppearanceSettings

    var body: some View {
        let theme = Theme.of(appearance.theme)
        ActivitySheet(store: store)
            .environment(\.inProgressPanel, true)
            .themed(theme)
            // 0.8.5 review: the close button mid-run, once per launch.
            .alert("Closing this window doesn't stop the upgrade.", isPresented: $store.progressPanelHideQuestion) {
                Button("Close Window") { store.answerProgressPanelHideQuestion(close: true) }
                Button("Keep Open", role: .cancel) { store.answerProgressPanelHideQuestion(close: false) }
            } message: {
                Text("Find it again in the menu bar.")
            }
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
