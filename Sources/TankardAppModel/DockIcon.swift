import Foundation

// 0.8.1: "Hide Dock icon when the window is closed" (Settings ▸ General).
// The decision lives here so it can be tested; AppDelegate (TankardApp.swift)
// applies it with NSApp.setActivationPolicy.

/// What the app's activation policy should be: `.regular` (Dock icon, app
/// menu, ⌘-Tab) or `.accessory` (only the menu-bar icon).
public enum DockIconPolicy: Equatable, Sendable {
    case regular
    case accessory

    /// The option only applies with the menu-bar icon on: without it a
    /// Tankard with no Dock icon and no window would be unreachable.
    public static func optionAvailable(showMenuBarIcon: Bool) -> Bool { showMenuBarIcon }

    /// `.accessory` only while no window is open (a minimized one counts as
    /// open: it lives in the Dock), the menu-bar icon is on and the option
    /// is on. Anything else, including any window opening, is `.regular`.
    public static func desired(windowOpen: Bool, showMenuBarIcon: Bool, hideDockIconWhenClosed: Bool) -> DockIconPolicy {
        !windowOpen && optionAvailable(showMenuBarIcon: showMenuBarIcon) && hideDockIconWhenClosed ? .accessory : .regular
    }

    /// The change to make, or nil when the app already has it (switching
    /// the policy to the one it has still flickers the menu bar).
    public static func transition(from current: DockIconPolicy, windowOpen: Bool, showMenuBarIcon: Bool,
                                  hideDockIconWhenClosed: Bool) -> DockIconPolicy? {
        let next = desired(windowOpen: windowOpen, showMenuBarIcon: showMenuBarIcon,
                           hideDockIconWhenClosed: hideDockIconWhenClosed)
        return next == current ? nil : next
    }
}

extension AppSettings {
    /// The policy for these settings and the given window state.
    public func dockIconPolicy(windowOpen: Bool) -> DockIconPolicy {
        DockIconPolicy.desired(windowOpen: windowOpen, showMenuBarIcon: showMenuBarIcon,
                               hideDockIconWhenClosed: hideDockIconWhenClosed)
    }
}
