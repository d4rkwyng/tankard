import AppKit
import TankardAppModel

/// 0.8.1: applies DockIconPolicy ("Hide Dock icon when the window is
/// closed"). With every window closed it switches to `.accessory` (no Dock
/// icon, no app menu, not in ⌘-Tab; the menu-bar icon stays). Any window
/// showing (main, Settings, About, a reopen) switches back to `.regular`.
@MainActor
final class DockIconController {
    private let settings: AppSettings
    private var current: DockIconPolicy = .regular
    private var observers: [NSObjectProtocol] = []

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        // A window showing: its occlusion changes, it becomes key or main.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        // At willClose the window is still visible: decide on the next turn.
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
        })
        observeSettings()
    }

    /// Before showing a window from the menu bar or a reopen: back to
    /// `.regular` first, so the window gets the Dock icon and the app menu.
    func prepareToShowWindow() {
        apply(.regular, activate: false)
    }

    /// A window that keeps the Dock icon: a titled window that is visible or
    /// minimized (it lives in the Dock). The menu-bar panel and the status
    /// item's window are not titled windows.
    static func counts(_ w: NSWindow) -> Bool {
        guard w.styleMask.contains(.titled), w.isVisible || w.isMiniaturized else { return false }
        if let p = w as? NSPanel, p.styleMask.contains(.nonactivatingPanel) { return false }
        let cls = String(describing: type(of: w))
        return !cls.contains("MenuBarExtra") && !cls.contains("StatusBar")
    }

    func update() {
        let open = NSApp.windows.contains(where: Self.counts)
        guard let next = DockIconPolicy.transition(from: current, windowOpen: open,
                                                   showMenuBarIcon: settings.showMenuBarIcon,
                                                   hideDockIconWhenClosed: settings.hideDockIconWhenClosed) else { return }
        apply(next, activate: open)
    }

    private func apply(_ policy: DockIconPolicy, activate: Bool) {
        guard policy != current else { return }
        current = policy
        switch policy {
        case .accessory:
            NSApp.setActivationPolicy(.accessory)
            // Hand the menu bar to the next app instead of a menu-less Tankard.
            NSApp.deactivate()
        case .regular:
            NSApp.setActivationPolicy(.regular)
            AppResources.reapplyDockIcon()
            // Activating in the same turn as the switch often leaves the
            // window behind and the app menu missing: activate on the next turn.
            if activate {
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    (NSApp.windows.first { $0.isVisible && $0.canBecomeKey && Self.counts($0) })?.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

    /// The menu-bar icon or the option changing (Settings, a script) is
    /// applied at once; turning the menu-bar icon off restores `.regular`.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.showMenuBarIcon
            _ = settings.hideDockIconWhenClosed
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.update()
                    self?.observeSettings()
                }
            }
        }
    }
}
