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
    /// 0.8.5 (test pass H1): the page's own size, as SwiftUI lays it out
    /// (ProgressPanelContent reports it); the panel's content follows it.
    private var pageSize: CGSize?
    /// A new panel waits (briefly) for its page's size before it shows.
    private var waitingForSize = false

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
            _ = store.progressPanelTitle
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
        // 0.8.5: "Upgrading 3 packages", "Upgrade finished", … (not a
        // second window called "Tankard").
        panel?.title = store.progressPanelTitle
    }

    private func show(front: Bool) {
        if let panel {
            if !panel.isVisible || front { present(panel) }
            return
        }
        let p = ProgressNSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.identifier = NSUserInterfaceItemIdentifier(Self.identifier)
        p.title = store.progressPanelTitle
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
        // 0.8.5 (test pass H1): the hosting view's preferredContentSize
        // option resized nothing (a plain window doesn't follow it; its
        // fitting size was 0×0), so every page was cut to 600×400 and lost
        // its title and buttons. The content now reports each page's size
        // and `fit` sets the panel to it, up to the screen's height (the
        // page scrolls past that).
        let host = NSHostingView(rootView: ProgressPanelContent(store: store, appearance: appearance) { [weak self] size in
            self?.fit(size)
        })
        host.sizingOptions = []
        p.contentView = host
        panel = p
        pageSize = nil
        waitingForSize = true
        host.layoutSubtreeIfNeeded()
        // Shown as soon as the size is known, or after a moment anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak p] in
            MainActor.assumeIsolated {
                guard let self, let p, self.panel === p, self.waitingForSize else { return }
                self.waitingForSize = false
                self.present(p)
            }
        }
    }

    /// The page's size changed (another page, more chips, a longer
    /// subtitle): the panel's content takes it, its top-left corner stays.
    private func fit(_ size: CGSize) {
        guard let p = panel, size.width >= 1, size.height >= 1 else { return }
        pageSize = size
        let screen = p.screen ?? Self.mouseScreen()
        let chrome = p.frame.height - p.contentLayoutRect.height
        let maxHeight = (screen?.visibleFrame.height ?? 900) - chrome - 16
        let content = NSSize(width: ceil(size.width), height: min(ceil(size.height), max(200, maxHeight)))
        let current = p.contentRect(forFrameRect: p.frame).size
        if abs(current.width - content.width) >= 1 || abs(current.height - content.height) >= 1 {
            var frame = p.frameRect(forContentRect: NSRect(origin: .zero, size: content))
            frame.origin = NSPoint(x: p.frame.minX, y: p.frame.maxY - frame.height)
            if p.isVisible, let visible = screen?.visibleFrame { frame = Self.clamp(frame, to: visible) }
            p.setFrame(frame, display: p.isVisible)
        }
        if waitingForSize {
            waitingForSize = false
            present(p)
        }
    }

    private static func mouseScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
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
        // The page's size is already set (`fit`), so centering uses it.
        let mouseScreen = Self.mouseScreen()
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
        waitingForSize = false
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
    /// The page's own size (each page sets its width; its height is what
    /// it needs), for the controller to size the panel.
    var pageSize: @MainActor (CGSize) -> Void

    var body: some View {
        let theme = Theme.of(appearance.theme)
        let report = pageSize
        // A page taller than the screen scrolls; otherwise the panel is
        // exactly its size and nothing scrolls.
        ScrollView(.vertical) {
            ActivitySheet(store: store)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { g in
                    // After this layout pass, not during it.
                    Color.clear
                        .onAppear { let s = g.size; DispatchQueue.main.async { MainActor.assumeIsolated { report(s) } } }
                        .onChange(of: g.size) { _, s in DispatchQueue.main.async { MainActor.assumeIsolated { report(s) } } }
                })
                .coordinateSpace(name: PanelLayoutProbe.space)
        }
        .scrollBounceBehavior(.basedOnSize)
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

/// 0.8.5: where each page's button row is in the panel's content, for
/// Scripts/panel-check.sh (Snapshot.panelCheck): SwiftUI's buttons aren't
/// NSViews and the accessibility tree is empty without an assistive app,
/// so the rows report their own frames, in the page's coordinates
/// (top-left origin; the panel's content shows exactly the page unless it
/// is taller than the screen).
@MainActor
final class PanelLayoutProbe {
    static let shared = PanelLayoutProbe()
    static let space = "tankard-progress-panel-page"
    var rows: [String: CGRect] = [:]
}

extension View {
    /// 0.8.5: marks a page's button row for the panel check (only in the
    /// progress panel).
    func panelButtonRow(_ name: String) -> some View {
        modifier(PanelButtonRow(name: name))
    }
}

private struct PanelButtonRow: ViewModifier {
    var name: String
    @Environment(\.inProgressPanel) private var inPanel

    func body(content: Content) -> some View {
        content.background {
            if inPanel {
                GeometryReader { g in
                    let frame = g.frame(in: .named(PanelLayoutProbe.space))
                    Color.clear
                        .onAppear { PanelLayoutProbe.shared.rows[name] = frame }
                        .onChange(of: frame) { _, f in PanelLayoutProbe.shared.rows[name] = f }
                        .onDisappear { PanelLayoutProbe.shared.rows[name] = nil }
                }
            }
        }
    }
}
